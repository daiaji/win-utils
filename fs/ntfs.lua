local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 16KB Buffer for Reparse Data
local REPARSE_BUFFER_SIZE = 16 * 1024

-- [Internal] Helper to create Reparse Data Buffer (Far Manager Style)
-- Essential for creating Junctions as there is no simple CreateJunction API in Windows.
local function create_reparse_buffer(tag, target_path, print_name)
    -- Junctions MUST rely on absolute NT paths (prefixed with \??\)
    local sub_name = target_path
    if not sub_name:match("^%\\%?%?\\") and not sub_name:match("^%\\%?%?%\\") then
        if sub_name:match("^%a:") then -- C:\... -> \??\C:\...
            sub_name = "\\??\\" .. sub_name
        end
    end
    
    local w_sub = util.to_wide(sub_name)
    local w_print = util.to_wide(print_name or target_path)
    
    local sub_len = (#sub_name) * 2
    local print_len = (#(print_name or target_path)) * 2
    
    -- Allocate struct size: Header + SubPath + PrintPath + Nulls
    local total_size = ffi.sizeof("MOUNT_POINT_REPARSE_BUFFER") + sub_len + print_len + 12
    local buf = ffi.new("uint8_t[?]", total_size)
    
    local header = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
    
    header.ReparseTag = tag
    header.ReparseDataLength = sub_len + print_len + 12
    header.Reserved = 0
    
    header.SubstituteNameOffset = 0
    header.SubstituteNameLength = sub_len
    header.PrintNameOffset = sub_len + 2
    header.PrintNameLength = print_len
    
    ffi.copy(header.PathBuffer, w_sub, sub_len)
    local ptr_print = ffi.cast("uint8_t*", header.PathBuffer) + header.PrintNameOffset
    ffi.copy(ptr_print, w_print, print_len)
    
    return buf, total_size
end

--------------------------------------------------------------------------------
-- 1. 链接创建 (Link Creation)
--------------------------------------------------------------------------------

-- 创建硬链接 (文件对文件)
-- @param link_path: 新链接的路径
-- @param target_path: 现有文件的路径
function M.mklink_hard(link_path, target_path)
    local w_link = util.to_wide(link_path)
    local w_target = util.to_wide(target_path)
    if kernel32.CreateHardLinkW(w_link, w_target, nil) == 0 then
        return false, util.format_error()
    end
    return true
end

-- 创建符号链接 (Symlink)
-- @param link_path: 链接路径
-- @param target_path: 目标路径 (可以是相对路径)
-- @param is_dir: boolean, 是否为目录链接
function M.mklink_sym(link_path, target_path, is_dir)
    local flags = 0
    if is_dir then flags = C.SYMBOLIC_LINK_FLAG_DIRECTORY end
    
    -- 在 PE 环境下，默认拥有 SeCreateSymbolicLinkPrivilege，无需特殊处理
    local res = kernel32.CreateSymbolicLinkW(util.to_wide(link_path), util.to_wide(target_path), flags)
    if res == 0 then return false, util.format_error() end
    return true
end

-- 创建 Junction (目录联接 point)
-- 相比 Symlink，Junction 必须指向绝对路径，且不需要特殊权限，兼容性更好
function M.mklink_junction(link_path, target_path)
    -- 1. 创建空目录
    if kernel32.CreateDirectoryW(util.to_wide(link_path), nil) == 0 then
        return false, "CreateDirectory failed: " .. util.format_error()
    end
    
    -- 2. 打开目录句柄 (需 WRITE 权限 + OPEN_REPARSE_POINT)
    local hFile = kernel32.CreateFileW(util.to_wide(link_path), 
        bit.bor(C.GENERIC_WRITE), 0, nil, C.OPEN_EXISTING, 
        bit.bor(C.FILE_FLAG_BACKUP_SEMANTICS, C.FILE_FLAG_OPEN_REPARSE_POINT), nil)
        
    if hFile == ffi.cast("HANDLE", -1) then 
        kernel32.RemoveDirectoryW(util.to_wide(link_path))
        return false, "Open directory failed: " .. util.format_error()
    end
    hFile = Handle.guard(hFile)
    
    -- 3. 构造并写入 Reparse Data
    local buf, size = create_reparse_buffer(C.IO_REPARSE_TAG_MOUNT_POINT, target_path)
    local bytes = ffi.new("DWORD[1]")
    
    local res = kernel32.DeviceIoControl(hFile, C.FSCTL_SET_REPARSE_POINT, buf, size, nil, 0, bytes, nil)
    if res == 0 then
        local err = util.format_error()
        Handle.close(hFile)
        kernel32.RemoveDirectoryW(util.to_wide(link_path))
        return false, err
    end
    
    return true
end

--------------------------------------------------------------------------------
-- 2. 链接解析 (Link Resolution)
--------------------------------------------------------------------------------

-- 读取链接目标 (支持 Symlink 和 Junction)
function M.read_link(path)
    local hFile = kernel32.CreateFileW(util.to_wide(path), 
        0, bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, 
        C.OPEN_EXISTING, 
        bit.bor(C.FILE_FLAG_BACKUP_SEMANTICS, C.FILE_FLAG_OPEN_REPARSE_POINT), nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return nil, "Open failed" end
    hFile = Handle.guard(hFile)
    
    local buf = ffi.new("uint8_t[?]", REPARSE_BUFFER_SIZE)
    local bytes = ffi.new("DWORD[1]")
    
    local res = kernel32.DeviceIoControl(hFile, C.FSCTL_GET_REPARSE_POINT, nil, 0, buf, REPARSE_BUFFER_SIZE, bytes, nil)
    if res == 0 then return nil, util.format_error() end
    
    local header = ffi.cast("REPARSE_DATA_BUFFER*", buf)
    local tag = header.ReparseTag
    
    local target, type_str
    
    if tag == C.IO_REPARSE_TAG_MOUNT_POINT then
        local mp = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
        local offset = mp.SubstituteNameOffset / 2
        local len = mp.SubstituteNameLength / 2
        target = util.from_wide(mp.PathBuffer + offset, len)
        type_str = "Junction"
        -- Remove NT prefix \??\
        if target:sub(1,4) == "\\??\\" then target = target:sub(5) end
        
    elseif tag == C.IO_REPARSE_TAG_SYMLINK then
        local sl = ffi.cast("SYMBOLIC_LINK_REPARSE_BUFFER*", buf)
        local offset = sl.SubstituteNameOffset / 2
        local len = sl.SubstituteNameLength / 2
        target = util.from_wide(sl.PathBuffer + offset, len)
        type_str = "Symlink"
        -- Remove NT prefix if present (Symlinks can be relative, usually don't have \??\)
        if target:sub(1,4) == "\\??\\" then target = target:sub(5) end
    else
        type_str = "Unknown"
    end
    
    return target, type_str
end

--------------------------------------------------------------------------------
-- 3. 安全删除 (Safe Deletion)
--------------------------------------------------------------------------------

-- 检查路径是否为 Reparse Point
function M.is_link(path)
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    if attr == 0xFFFFFFFF then return false end
    return bit.band(attr, C.FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
end

-- 安全移除链接
-- 如果是目录链接，只移除链接本身，不删除目标内容。
-- 如果是普通文件/目录，返回错误（防止误删数据）。
function M.unlink(path)
    local wpath = util.to_wide(path)
    local attr = kernel32.GetFileAttributesW(wpath)
    
    if attr == 0xFFFFFFFF then return false, "Path not found" end
    
    -- 必须是 Reparse Point
    if bit.band(attr, C.FILE_ATTRIBUTE_REPARSE_POINT) == 0 then
        return false, "Not a link (Safety guard)"
    end
    
    -- 如果是目录
    if bit.band(attr, C.FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
        if kernel32.RemoveDirectoryW(wpath) == 0 then
            return false, util.format_error()
        end
    else
        -- 如果是文件 Symlink
        if kernel32.DeleteFileW(wpath) == 0 then
            return false, util.format_error()
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- 4. 高级属性 (Compression & Sparse)
--------------------------------------------------------------------------------

-- 设置 NTFS 压缩
-- @param state: 0=None, 1=Default (LZNT1)
function M.set_compression(path, state)
    local hFile = kernel32.CreateFileW(util.to_wide(path), 
        bit.bor(C.GENERIC_READ, C.GENERIC_WRITE), 
        bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, 
        C.OPEN_EXISTING, 
        bit.bor(C.FILE_FLAG_BACKUP_SEMANTICS), nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, util.format_error() end
    hFile = Handle.guard(hFile)
    
    local in_buf = ffi.new("uint16_t[1]")
    in_buf[0] = state and C.COMPRESSION_FORMAT_DEFAULT or C.COMPRESSION_FORMAT_NONE
    
    local bytes = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(hFile, C.FSCTL_SET_COMPRESSION, 
        in_buf, 2, nil, 0, bytes, nil)
        
    if res == 0 then return false, util.format_error() end
    return true
end

-- 设置稀疏文件 (Sparse)
function M.set_sparse(path, enable)
    local hFile = kernel32.CreateFileW(util.to_wide(path), 
        bit.bor(C.GENERIC_WRITE), 0, nil, C.OPEN_EXISTING, 0, nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, util.format_error() end
    hFile = Handle.guard(hFile)
    
    local bytes = ffi.new("DWORD[1]")
    -- FSCTL_SET_SPARSE 仅用于启用。Windows 不推荐禁用稀疏标志。
    if enable then
        if kernel32.DeviceIoControl(hFile, C.FSCTL_SET_SPARSE, nil, 0, nil, 0, bytes, nil) == 0 then
            return false, util.format_error()
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- 5. ADS (Alternate Data Streams)
--------------------------------------------------------------------------------

function M.list_streams(path)
    local hFind = ffi.new("HANDLE[1]")
    local data = ffi.new("WIN32_FIND_STREAM_DATA")
    
    -- InfoLevel = 0 (Standard)
    hFind[0] = kernel32.FindFirstStreamW(util.to_wide(path), 0, data, 0)
    
    if hFind[0] == ffi.cast("HANDLE", -1) then
        local err = kernel32.GetLastError()
        if err == 38 then return {} end -- ERROR_HANDLE_EOF
        return nil, util.format_error(err)
    end
    
    local streams = {}
    repeat
        table.insert(streams, {
            name = util.from_wide(data.cStreamName),
            size = tonumber(data.StreamSize.QuadPart)
        })
    until kernel32.FindNextStreamW(hFind[0], data) == 0
    
    kernel32.FindClose(hFind[0])
    return streams
end

return M