local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 辅助：创建 Reparse Buffer (Junction)
local function create_junction_buffer(target)
    local sub = target:match("^%a:") and ("\\??\\" .. target) or target
    local w_sub = util.to_wide(sub)
    local w_print = util.to_wide(target)
    local sub_len = #sub * 2
    local print_len = #target * 2
    
    local size = ffi.sizeof("MOUNT_POINT_REPARSE_BUFFER") + sub_len + print_len + 12
    local buf = ffi.new("uint8_t[?]", size)
    local hdr = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
    
    hdr.ReparseTag = C.IO_REPARSE_TAG_MOUNT_POINT
    hdr.ReparseDataLength = sub_len + print_len + 12
    hdr.SubstituteNameLength = sub_len
    hdr.PrintNameOffset = sub_len + 2
    hdr.PrintNameLength = print_len
    
    ffi.copy(hdr.PathBuffer, w_sub, sub_len)
    ffi.copy(ffi.cast("uint8_t*", hdr.PathBuffer) + hdr.PrintNameOffset, w_print, print_len)
    
    return buf, size
end

function M.mklink_hard(link, target)
    return kernel32.CreateHardLinkW(util.to_wide(link), util.to_wide(target), nil) ~= 0
end

function M.mklink_sym(link, target, is_dir)
    return kernel32.CreateSymbolicLinkW(util.to_wide(link), util.to_wide(target), is_dir and 1 or 0) ~= 0
end

function M.mklink_junction(link, target)
    if kernel32.CreateDirectoryW(util.to_wide(link), nil) == 0 then return false, util.format_error() end
    local h = kernel32.CreateFileW(util.to_wide(link), 0x40000000, 0, nil, 3, 0x02200000, nil) -- GENERIC_WRITE, OPEN_EXISTING, BACKUP_SEMANTICS|OPEN_REPARSE_POINT
    if h == ffi.cast("HANDLE", -1) then kernel32.RemoveDirectoryW(util.to_wide(link)); return false, util.format_error() end
    
    local buf, size = create_junction_buffer(target)
    local res = util.ioctl(h, C.FSCTL_SET_REPARSE_POINT, buf, size)
    kernel32.CloseHandle(h)
    
    if not res then kernel32.RemoveDirectoryW(util.to_wide(link)) end
    return res ~= nil
end

function M.read_link(path)
    local h = kernel32.CreateFileW(util.to_wide(path), 0, 0x7, nil, 3, 0x02200000, nil)
    if h == ffi.cast("HANDLE", -1) then return nil end
    local buf = util.ioctl(h, C.FSCTL_GET_REPARSE_POINT, nil, 0, nil, 16384)
    kernel32.CloseHandle(h)
    
    if not buf then return nil end
    local hdr = ffi.cast("REPARSE_DATA_BUFFER*", buf)
    
    if hdr.ReparseTag == C.IO_REPARSE_TAG_MOUNT_POINT then
        local mp = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
        local t = util.from_wide(mp.PathBuffer + mp.SubstituteNameOffset/2, mp.SubstituteNameLength/2)
        return t:match("^%\\%?%?\\") and t:sub(5) or t, "Junction"
    elseif hdr.ReparseTag == C.IO_REPARSE_TAG_SYMLINK then
        local sl = ffi.cast("SYMBOLIC_LINK_REPARSE_BUFFER*", buf)
        local t = util.from_wide(sl.PathBuffer + sl.SubstituteNameOffset/2, sl.SubstituteNameLength/2)
        return t:match("^%\\%?%?\\") and t:sub(5) or t, "Symlink"
    end
    return nil, "Unknown"
end

function M.is_link(path)
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    return attr ~= 0xFFFFFFFF and bit.band(attr, 0x400) ~= 0
end

function M.unlink(path)
    local w = util.to_wide(path)
    local a = kernel32.GetFileAttributesW(w)
    if a == 0xFFFFFFFF or bit.band(a, 0x400) == 0 then return false, "Not a link" end
    if bit.band(a, 0x10) ~= 0 then return kernel32.RemoveDirectoryW(w) ~= 0 else return kernel32.DeleteFileW(w) ~= 0 end
end

function M.set_compression(path, state)
    local h = kernel32.CreateFileW(util.to_wide(path), 0xC0000000, 0x7, nil, 3, 0x02000000, nil)
    if h == ffi.cast("HANDLE", -1) then return false end
    local buf = ffi.new("uint16_t[1]", state and 1 or 0)
    local res = util.ioctl(h, C.FSCTL_SET_COMPRESSION, buf, 2)
    kernel32.CloseHandle(h)
    return res ~= nil
end

function M.set_sparse(path, enable)
    if not enable then return true end -- Cannot disable
    local h = kernel32.CreateFileW(util.to_wide(path), 0x40000000, 0, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return false end
    local res = util.ioctl(h, C.FSCTL_SET_SPARSE)
    kernel32.CloseHandle(h)
    return res ~= nil
end

function M.list_streams(path)
    local hFind = ffi.new("HANDLE[1]")
    local data = ffi.new("WIN32_FIND_STREAM_DATA")
    hFind[0] = kernel32.FindFirstStreamW(util.to_wide(path), 0, data, 0)
    if hFind[0] == ffi.cast("HANDLE", -1) then return {} end -- No streams or file not found
    
    local s = {}
    repeat table.insert(s, { name = util.from_wide(data.cStreamName), size = tonumber(data.StreamSize.QuadPart) })
    until kernel32.FindNextStreamW(hFind[0], data) == 0
    kernel32.FindClose(hFind[0])
    return s
end

return M