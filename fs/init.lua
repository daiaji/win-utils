local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local version = require 'ffi.req' 'Windows.sdk.version'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'

-- [Lazy Load] 避免循环依赖
local function get_ntfs() return require 'win-utils.fs.ntfs' end
local function get_raw() return require 'win-utils.fs.raw' end

local M = {}

local sub_modules = {
    native = 'win-utils.fs.raw',
    ntfs   = 'win-utils.fs.ntfs',
    path   = 'win-utils.fs.path',
    acl    = 'win-utils.fs.acl'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

-- 常量定义
local FILE_ATTRIBUTE_DIRECTORY     = 0x10
local FILE_ATTRIBUTE_REPARSE_POINT = 0x400
local FILE_ATTRIBUTE_READONLY      = 0x01
local INVALID_FILE_ATTRIBUTES      = 0xFFFFFFFF

-- [Internal] Native Directory Iterator
local function scandir_native(path)
    local h, err = native.open_file(path, "r", true) 
    if not h then return function() end end
    
    local buf_size = 4096
    local buf = ffi.new("uint8_t[?]", buf_size)
    local io = ffi.new("IO_STATUS_BLOCK")
    
    local first_call = true
    local current_ptr = nil
    local done = false
    
    return function()
        if done then return nil end
        
        while true do
            if current_ptr then
                local info = ffi.cast("FILE_DIRECTORY_INFORMATION*", current_ptr)
                local name = util.from_wide(info.FileName, info.FileNameLength / 2)
                local attr = info.FileAttributes
                
                local next_off = info.NextEntryOffset
                if next_off == 0 then current_ptr = nil
                else current_ptr = current_ptr + next_off end
                
                if name ~= "." and name ~= ".." then 
                    return name, attr 
                end
            else
                -- ReturnSingleEntry=false, RestartScan=first_call
                local status = ntdll.NtQueryDirectoryFile(h:get(), nil, nil, nil, io, buf, buf_size, 1, false, nil, first_call)
                first_call = false
                if status < 0 then h:close(); done = true; return nil end
                current_ptr = buf
            end
        end
    end
end

-- [Safety] 检查是否为链接 (Symlink / Junction)
local function is_link(attr)
    return bit.band(attr, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
end

-- [Safety] 检查是否为目录
local function is_dir(attr)
    return bit.band(attr, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

-- ========================================================================
-- Coreutils-like Operations
-- ========================================================================

-- [mkdir -p] 递归创建目录
function M.mkdir(path, opts)
    opts = opts or {}
    -- 默认行为：如果 opts.p 为真，则递归创建
    local make_parents = opts.parents or opts.p
    
    path = util.normalize_path(path)
    if not path then return false, "Invalid path" end
    
    if not make_parents then
        if kernel32.CreateDirectoryW(util.to_wide(path), nil) ~= 0 then return true end
        local err = kernel32.GetLastError()
        if err == 183 then return true end -- ALREADY_EXISTS
        return false, util.last_error()
    end

    -- mkdir -p 逻辑
    local parts = util.split_path(path)
    local current = ""
    
    -- 处理盘符或 UNC 头
    local start_idx = 1
    if path:match("^%a:\\") then
        current = parts[1] .. "\\"
        start_idx = 2
    elseif path:match("^\\\\") then
        -- 简易处理 UNC: \\Server\Share
        current = "\\\\" .. parts[1] .. "\\" .. parts[2] .. "\\"
        start_idx = 3
    elseif path:match("^\\") then
        current = "\\"
    end

    for i = start_idx, #parts do
        current = current .. parts[i]
        -- 检查是否存在 (CreateDirectory 失败开销较大，先检查)
        if not M.is_dir(current) then
            if kernel32.CreateDirectoryW(util.to_wide(current), nil) == 0 then
                local err = kernel32.GetLastError()
                if err ~= 183 then 
                    return false, "Failed to create " .. current .. ": " .. util.last_error()
                end
            end
        end
        current = current .. "\\"
    end
    return true
end

-- [cp -r] 递归复制
local function cp_r(src, dst, opts)
    opts = opts or {}
    local raw = get_raw()
    
    -- 1. 获取源信息
    local src_info, err = raw.get_file_info(src)
    if not src_info then return false, "Source not found or inaccessible" end
    
    local attr = src_info.attr
    
    -- 2. 链接处理 (Coreutils -P 行为: 默认保留链接，不追随)
    if is_link(attr) then
        local ntfs = get_ntfs()
        local target, type = ntfs.read_link(src)
        if target then
            local is_d = is_dir(attr)
            return ntfs.mklink(dst, target, type == "Junction" and "junction" or (is_d and "dir" or "file"))
        end
        return false, "Read link failed"
    end
    
    -- 3. 目录处理
    if is_dir(attr) then
        -- 循环检测 (防止 cp -r dir dir/subdir)
        local src_norm = util.normalize_path(src):lower()
        local dst_norm = util.normalize_path(dst):lower()
        if dst_norm:find(src_norm, 1, true) == 1 then
            return false, "Cannot copy directory into itself: " .. src .. " -> " .. dst
        end
        
        -- 创建目标目录 (类似 mkdir -p，确保存在)
        if kernel32.CreateDirectoryW(util.to_wide(dst), nil) == 0 then
            local e = kernel32.GetLastError()
            if e ~= 183 then return false, util.last_error() end
        end
        
        -- 递归
        for name, _ in scandir_native(src) do
            local ok, err = cp_r(src .. "\\" .. name, dst .. "\\" .. name, opts)
            if not ok then return false, err end
        end
        
        -- 目录属性保留
        if opts.preserve then
            raw.set_times(dst, src_info.ctime, src_info.atime, src_info.mtime)
            raw.set_attributes(dst, attr)
        end
        
        return true
    end
    
    -- 4. 文件处理
    local fail_if_exists = opts.no_clobber or false
    
    local r = kernel32.CopyFileW(util.to_wide(src), util.to_wide(dst), fail_if_exists and 1 or 0)
    if r == 0 then return false, util.last_error() end
    
    -- 文件属性保留 (CopyFile 默认保留时间/属性，但为保险起见或处理特殊情况可显式调用)
    if opts.preserve and opts.acl then
        -- TODO: ACL copy logic if needed
    end
    
    return true
end

function M.copy(src, dst, opts) return cp_r(src, dst, opts or {}) end

-- [rm -rf] 递归删除
local function rm_rf(path)
    local raw = get_raw()
    
    -- 1. 获取属性
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    if attr == INVALID_FILE_ATTRIBUTES then return true end -- 已经不存在
    
    -- 2. 递归清空目录 (但不递归进链接)
    if is_dir(attr) and not is_link(attr) then
        local ok = true
        for name, _ in scandir_native(path) do
            if not rm_rf(path .. "\\" .. name) then ok = false end
        end
        if not ok then return false, "Failed to clean directory contents" end
    end
    
    -- 3. 移除只读
    if bit.band(attr, FILE_ATTRIBUTE_READONLY) ~= 0 then
        kernel32.SetFileAttributesW(util.to_wide(path), 0x80) -- NORMAL
    end
    
    -- 4. 删除自身
    if is_dir(attr) and not is_link(attr) then
        if kernel32.RemoveDirectoryW(util.to_wide(path)) == 0 then
            return false, util.last_error()
        end
    else
        -- POSIX 语义删除 (更强力)
        if not raw.delete_posix(path) then
            if kernel32.DeleteFileW(util.to_wide(path)) == 0 then
                return false, util.last_error()
            end
        end
    end
    
    return true
end

function M.delete(path) return rm_rf(path) end
function M.recycle(path) return rm_rf(path) end -- PE 环境下直接删除

-- [mv] 移动 (原子性 + 跨卷回退)
function M.move(src, dst, opts)
    opts = opts or {}
    -- MOVEFILE_COPY_ALLOWED (2) | MOVEFILE_REPLACE_EXISTING (1) | MOVEFILE_WRITE_THROUGH (8)
    local flags = 2 + 8
    if not opts.no_clobber then flags = flags + 1 end
    
    -- 1. 尝试原子移动
    if kernel32.MoveFileExW(util.to_wide(src), util.to_wide(dst), flags) ~= 0 then
        return true
    end
    
    local err_code = kernel32.GetLastError()
    
    -- 2. 处理跨卷 (ERROR_NOT_SAME_DEVICE = 17)
    if err_code == 17 then
        -- 降级为 Copy + Delete
        local ok, copy_err = M.copy(src, dst, opts)
        if not ok then return false, "Cross-drive copy failed: " .. tostring(copy_err) end
        
        local del_ok, del_err = M.delete(src)
        if not del_ok then
            -- 这是一个严重的中间状态：复制成功但源无法删除
            return false, "Move completed but source cleanup failed: " .. tostring(del_err)
        end
        return true
    end
    
    return false, util.last_error()
end

-- [touch] 创建/更新时间
function M.touch(path)
    local h = kernel32.CreateFileW(util.to_wide(path), 
        bit.bor(0x80000000, 0x40000000), -- READ|WRITE
        0, nil, 
        4, -- OPEN_ALWAYS
        0x80, nil)
    
    if h == ffi.cast("HANDLE", -1) then return false, util.last_error() end
    
    local t = ffi.new("FILETIME")
    kernel32.GetSystemTimeAsFileTime(t)
    kernel32.SetFileTime(h, nil, nil, t)
    kernel32.CloseHandle(h)
    return true
end

-- [stat] 获取详细信息
function M.stat(path)
    local raw = get_raw()
    local info, err = raw.get_file_info(path)
    if not info then return nil, err end
    
    info.is_dir = is_dir(info.attr)
    info.is_link = is_link(info.attr)
    return info
end

-- 属性查询
function M.exists(path) return kernel32.GetFileAttributesW(util.to_wide(path)) ~= INVALID_FILE_ATTRIBUTES end

function M.is_dir(path)
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    return a ~= INVALID_FILE_ATTRIBUTES and is_dir(a)
end

function M.is_link(path)
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    return a ~= INVALID_FILE_ATTRIBUTES and is_link(a)
end

function M.get_version(path)
    local w = util.to_wide(path)
    local d = ffi.new("DWORD[1]")
    local sz = version.GetFileVersionInfoSizeW(w, d)
    if sz == 0 then return nil end
    local buf = ffi.new("uint8_t[?]", sz)
    if version.GetFileVersionInfoW(w, 0, sz, buf) == 0 then return nil end
    local info = ffi.new("VS_FIXEDFILEINFO*[1]")
    local len = ffi.new("UINT[1]")
    if version.VerQueryValueW(buf, util.to_wide("\\"), ffi.cast("void**", info), len) == 0 then return nil end
    local v = info[0]
    return string.format("%d.%d.%d.%d", 
        bit.rshift(v.dwFileVersionMS, 16), bit.band(v.dwFileVersionMS, 0xFFFF), 
        bit.rshift(v.dwFileVersionLS, 16), bit.band(v.dwFileVersionLS, 0xFFFF))
end

-- 迭代器暴露
function M.scandir(path)
    return scandir_native(path)
end

return M