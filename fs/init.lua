local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local version = require 'ffi.req' 'Windows.sdk.version' -- Ensure this binding exists
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'

-- Lazy load submodules
local sub_modules = {
    native = 'win-utils.fs.raw',
    ntfs   = 'win-utils.fs.ntfs',
    path   = 'win-utils.fs.path',
    acl    = 'win-utils.fs.acl'
}

local M = {}
local mt = {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
}
setmetatable(M, mt)

local function get_ntfs() return M.ntfs end
local function get_raw() return M.native end

local FILE_ATTRIBUTE_DIRECTORY     = 0x10
local FILE_ATTRIBUTE_REPARSE_POINT = 0x400
local FILE_ATTRIBUTE_READONLY      = 0x01
local INVALID_FILE_ATTRIBUTES      = 0xFFFFFFFF

local function is_link_attr(attr) return bit.band(attr, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 end
local function is_dir_attr(attr) return bit.band(attr, FILE_ATTRIBUTE_DIRECTORY) ~= 0 end

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
                local size = info.EndOfFile.QuadPart
                local next_off = info.NextEntryOffset
                if next_off == 0 then current_ptr = nil
                else current_ptr = current_ptr + next_off end
                if name ~= "." and name ~= ".." then return name, attr, tonumber(size) end
            else
                local status = ntdll.NtQueryDirectoryFile(h:get(), nil, nil, nil, io, buf, buf_size, 1, false, nil, first_call)
                first_call = false
                if status < 0 then h:close(); done = true; return nil end
                current_ptr = buf
            end
        end
    end
end

-- [RESTORED] Get File Version String (e.g., "1.0.0.0")
function M.get_version(path)
    local wpath = util.to_wide(path)
    local dummy = ffi.new("DWORD[1]")
    local size = version.GetFileVersionInfoSizeW(wpath, dummy)
    if size == 0 then return nil end

    local buf = ffi.new("uint8_t[?]", size)
    if version.GetFileVersionInfoW(wpath, 0, size, buf) == 0 then return nil end

    local verInfo = ffi.new("VS_FIXEDFILEINFO*[1]")
    local verLen = ffi.new("UINT[1]")
    
    if version.VerQueryValueW(buf, util.to_wide("\\"), ffi.cast("void**", verInfo), verLen) == 0 then return nil end

    local vi = verInfo[0]
    return string.format("%d.%d.%d.%d",
        bit.rshift(vi.dwFileVersionMS, 16), bit.band(vi.dwFileVersionMS, 0xFFFF),
        bit.rshift(vi.dwFileVersionLS, 16), bit.band(vi.dwFileVersionLS, 0xFFFF))
end

function M.mkdir(path, opts)
    opts = opts or {}
    local make_parents = opts.parents or opts.p
    path = util.normalize_path(path)
    if not path then return false, "Invalid path" end
    
    if not make_parents then
        if kernel32.CreateDirectoryW(util.to_wide(path), nil) ~= 0 then return true end
        local err = kernel32.GetLastError()
        if err == 183 then return true end -- ALREADY_EXISTS
        return false, util.last_error()
    end

    local parts = util.split_path(path)
    local current = ""
    local start_idx = 1
    if path:match("^%a:\\") then current = parts[1] .. "\\"; start_idx = 2
    elseif path:match("^\\\\") then current = "\\\\" .. parts[1] .. "\\" .. parts[2] .. "\\"; start_idx = 3
    elseif path:match("^\\") then current = "\\" end

    for i = start_idx, #parts do
        current = current .. parts[i]
        if not M.is_dir(current) then
            if kernel32.CreateDirectoryW(util.to_wide(current), nil) == 0 then
                if kernel32.GetLastError() ~= 183 then 
                    return false, "Failed to create " .. current .. ": " .. util.last_error()
                end
            end
        end
        current = current .. "\\"
    end
    return true
end

local function cp_r(src, dst, opts)
    opts = opts or {}
    local raw = get_raw()
    local src_info, err = raw.get_file_info(src)
    if not src_info then return false, "Source inaccessible: " .. tostring(err) end
    local attr = src_info.attr
    
    if is_link_attr(attr) then
        local ntfs = get_ntfs()
        local target, type = ntfs.read_link(src)
        if target then
            return ntfs.mklink(dst, target, type == "Junction" and "junction" or (is_dir_attr(attr) and "dir" or "file"))
        end
        return false, "Read link failed"
    end
    
    if is_dir_attr(attr) then
        local src_norm = util.normalize_path(src):lower()
        local dst_norm = util.normalize_path(dst):lower()
        if dst_norm:find(src_norm, 1, true) == 1 then return false, "Recursion detected" end
        
        if kernel32.CreateDirectoryW(util.to_wide(dst), nil) == 0 and kernel32.GetLastError() ~= 183 then
            return false, util.last_error()
        end
        
        for name in scandir_native(src) do
            local ok, err = cp_r(src .. "\\" .. name, dst .. "\\" .. name, opts)
            if not ok then return false, err end
        end
        
        if opts.preserve then
            raw.set_times(dst, src_info.ctime, src_info.atime, src_info.mtime)
            raw.set_attributes(dst, attr)
        end
        return true
    end
    
    local r = kernel32.CopyFileW(util.to_wide(src), util.to_wide(dst), opts.no_clobber and 1 or 0)
    if r == 0 then return false, util.last_error() end
    return true
end

function M.copy(src, dst, opts) return cp_r(src, dst, opts or {}) end

local function rm_rf(path)
    local raw = get_raw()
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    if attr == INVALID_FILE_ATTRIBUTES then return true end
    
    if is_dir_attr(attr) and not is_link_attr(attr) then
        local ok = true
        for name in scandir_native(path) do
            if not rm_rf(path .. "\\" .. name) then ok = false end
        end
        if not ok then return false, "Clean dir failed" end
    end
    
    if bit.band(attr, FILE_ATTRIBUTE_READONLY) ~= 0 then
        kernel32.SetFileAttributesW(util.to_wide(path), 0x80)
    end
    
    if is_dir_attr(attr) and not is_link_attr(attr) then
        if kernel32.RemoveDirectoryW(util.to_wide(path)) == 0 then return false, util.last_error() end
    else
        if not raw.delete_posix(path) then
            if kernel32.DeleteFileW(util.to_wide(path)) == 0 then return false, util.last_error() end
        end
    end
    return true
end

function M.delete(path) return rm_rf(path) end

function M.move(src, dst, opts)
    opts = opts or {}
    local flags = 10 -- COPY_ALLOWED | WRITE_THROUGH
    if not opts.no_clobber then flags = flags + 1 end
    
    if kernel32.MoveFileExW(util.to_wide(src), util.to_wide(dst), flags) ~= 0 then return true end
    
    if kernel32.GetLastError() == 17 then -- ERROR_NOT_SAME_DEVICE
        if M.copy(src, dst, opts) then return M.delete(src) end
        return false, "Copy failed during cross-drive move"
    end
    return false, util.last_error()
end

function M.get_space_info(path)
    local wpath = util.to_wide(path or ".")
    local free_user = ffi.new("ULARGE_INTEGER")
    local total = ffi.new("ULARGE_INTEGER")
    local free_total = ffi.new("ULARGE_INTEGER")
    
    if kernel32.GetDiskFreeSpaceExW(wpath, free_user, total, free_total) == 0 then
        return nil, util.last_error()
    end
    
    local total_val = tonumber(total.QuadPart)
    local free_val = tonumber(free_user.QuadPart)
    
    return {
        free_bytes = free_val,
        total_bytes = total_val,
        free_total_bytes = tonumber(free_total.QuadPart),
        percent_free = (total_val > 0) and (free_val / total_val) or 0
    }
end

function M.get_usage_info(path, opts)
    opts = opts or {}
    local raw = get_raw()
    local stats = { size = 0, disk_usage = 0, files = 0, dirs = 0, seen = {} }
    
    local function recurse(p)
        local info, err = raw.get_file_info(p)
        if not info then return end
        
        local id = string.format("%d:%s", info.vol_serial, tostring(info.file_index))
        if stats.seen[id] then return end
        stats.seen[id] = true
        
        if is_dir_attr(info.attr) then
            stats.dirs = stats.dirs + 1
            if not is_link_attr(info.attr) then 
                for name in scandir_native(p) do recurse(p .. "\\" .. name) end
            end
        else
            stats.files = stats.files + 1
            stats.size = stats.size + tonumber(info.size)
            if opts.apparent_size then
                stats.disk_usage = stats.disk_usage + tonumber(info.size)
            else
                local phy = raw.get_physical_size(p)
                stats.disk_usage = stats.disk_usage + (phy or tonumber(info.size))
            end
        end
    end
    
    recurse(util.normalize_path(path))
    stats.seen = nil 
    return stats
end

function M.find(path, opts)
    opts = opts or {}
    path = util.normalize_path(path)
    local q = { path }
    local head, tail = 1, 1
    
    return function()
        while head <= tail do
            local curr = q[head]
            head = head + 1
            local attr = kernel32.GetFileAttributesW(util.to_wide(curr))
            if attr ~= INVALID_FILE_ATTRIBUTES then
                local is_d = is_dir_attr(attr)
                if is_d and opts.recursive ~= false and not is_link_attr(attr) then
                    for name in scandir_native(curr) do
                        tail = tail + 1
                        q[tail] = curr .. "\\" .. name
                    end
                end
                local match = true
                if opts.type == "f" and is_d then match = false end
                if opts.type == "d" and not is_d then match = false end
                if match then return curr, attr end
            end
        end
        return nil
    end
end

function M.wipe(path, opts)
    opts = opts or {}
    local passes = opts.passes or 3
    local h = native.open_file(path, "w", "exclusive")
    if not h then return false, "Cannot open file" end
    
    local sz = ffi.new("LARGE_INTEGER")
    kernel32.GetFileSizeEx(h:get(), sz)
    local len = tonumber(sz.QuadPart)
    
    if len > 0 then
        local buf_size = 64*1024
        local buf = ffi.new("uint8_t[?]", buf_size)
        local written = ffi.new("DWORD[1]")
        
        for i=1, passes do
            kernel32.SetFilePointer(h:get(), 0, nil, 0)
            local remain = len
            while remain > 0 do
                local chunk = math.min(remain, buf_size)
                for b=0, chunk-1 do buf[b] = math.random(0, 255) end
                kernel32.WriteFile(h:get(), buf, chunk, written, nil)
                remain = remain - written[0]
            end
            kernel32.FlushFileBuffers(h:get())
        end
    end
    
    h:close()
    return M.delete(path)
end

function M.link(target, linkname, opts)
    opts = opts or {}
    local ntfs = get_ntfs()
    local type = "file"
    if M.is_dir(target) then type = "dir" end
    if opts.symbolic then return ntfs.mklink(linkname, target, type)
    else return ntfs.mklink(linkname, target, "hard") end
end

function M.update_timestamps(path)
    local h = kernel32.CreateFileW(util.to_wide(path), bit.bor(0x80000000, 0x40000000), 0, nil, 4, 0x80, nil)
    if h == ffi.cast("HANDLE", -1) then return false, util.last_error() end
    local t = ffi.new("FILETIME")
    kernel32.GetSystemTimeAsFileTime(t)
    kernel32.SetFileTime(h, nil, nil, t)
    kernel32.CloseHandle(h)
    return true
end

function M.exists(path) return kernel32.GetFileAttributesW(util.to_wide(path)) ~= INVALID_FILE_ATTRIBUTES end
function M.is_dir(path) 
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    return a ~= INVALID_FILE_ATTRIBUTES and is_dir_attr(a) 
end
function M.is_link(path) 
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    return a ~= INVALID_FILE_ATTRIBUTES and is_link_attr(a) 
end
function M.scandir(path) return scandir_native(path) end
function M.stat(path)
    local raw = get_raw()
    local info, err = raw.get_file_info(path)
    if not info then return nil, err end
    info.is_dir = is_dir_attr(info.attr)
    info.is_link = is_link_attr(info.attr)
    return info
end

return M