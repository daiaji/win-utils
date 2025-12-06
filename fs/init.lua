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
    -- [REMOVED] acl is explicitly excluded for PE environment
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
                local size = info.EndOfFile.QuadPart
                
                local next_off = info.NextEntryOffset
                if next_off == 0 then current_ptr = nil
                else current_ptr = current_ptr + next_off end
                
                if name ~= "." and name ~= ".." then 
                    return name, attr, tonumber(size)
                end
            else
                local status = ntdll.NtQueryDirectoryFile(h:get(), nil, nil, nil, io, buf, buf_size, 1, false, nil, first_call)
                first_call = false
                if status < 0 then h:close(); done = true; return nil end
                current_ptr = buf
            end
        end
    end
end

local function is_link(attr) return bit.band(attr, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 end
local function is_dir(attr) return bit.band(attr, FILE_ATTRIBUTE_DIRECTORY) ~= 0 end

-- ========================================================================
-- Coreutils: Operations
-- ========================================================================

-- [mkdir -p]
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

-- [cp -r]
local function cp_r(src, dst, opts)
    opts = opts or {}
    local raw = get_raw()
    local src_info, err = raw.get_file_info(src)
    if not src_info then return false, "Source inaccessible" end
    local attr = src_info.attr
    
    -- Symlink (No Dereference)
    if is_link(attr) then
        local ntfs = get_ntfs()
        local target, type = ntfs.read_link(src)
        if target then
            return ntfs.mklink(dst, target, type == "Junction" and "junction" or (is_dir(attr) and "dir" or "file"))
        end
        return false, "Read link failed"
    end
    
    -- Directory
    if is_dir(attr) then
        -- Loop detection
        local src_norm = util.normalize_path(src):lower()
        local dst_norm = util.normalize_path(dst):lower()
        if dst_norm:find(src_norm, 1, true) == 1 then
            return false, "Recursion detected"
        end
        
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
    
    -- File
    local r = kernel32.CopyFileW(util.to_wide(src), util.to_wide(dst), opts.no_clobber and 1 or 0)
    if r == 0 then return false, util.last_error() end
    
    -- Attributes are copied by CopyFileW automatically.
    return true
end

function M.copy(src, dst, opts) return cp_r(src, dst, opts or {}) end

-- [rm -rf]
local function rm_rf(path)
    local raw = get_raw()
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    if attr == INVALID_FILE_ATTRIBUTES then return true end
    
    if is_dir(attr) and not is_link(attr) then
        local ok = true
        for name in scandir_native(path) do
            if not rm_rf(path .. "\\" .. name) then ok = false end
        end
        if not ok then return false, "Clean dir failed" end
    end
    
    if bit.band(attr, FILE_ATTRIBUTE_READONLY) ~= 0 then
        kernel32.SetFileAttributesW(util.to_wide(path), 0x80)
    end
    
    if is_dir(attr) and not is_link(attr) then
        if kernel32.RemoveDirectoryW(util.to_wide(path)) == 0 then return false, util.last_error() end
    else
        if not raw.delete_posix(path) then
            if kernel32.DeleteFileW(util.to_wide(path)) == 0 then return false, util.last_error() end
        end
    end
    return true
end

function M.delete(path) return rm_rf(path) end
function M.recycle(path) return rm_rf(path) end

-- [mv]
function M.move(src, dst, opts)
    opts = opts or {}
    local flags = 10 -- COPY_ALLOWED | WRITE_THROUGH
    if not opts.no_clobber then flags = flags + 1 end
    
    if kernel32.MoveFileExW(util.to_wide(src), util.to_wide(dst), flags) ~= 0 then return true end
    
    if kernel32.GetLastError() == 17 then -- ERROR_NOT_SAME_DEVICE
        if M.copy(src, dst, opts) then
            return M.delete(src)
        end
        return false, "Copy failed during cross-drive move"
    end
    return false, util.last_error()
end

-- ========================================================================
-- Advanced Tools
-- ========================================================================

-- [df] Disk Free
function M.df(path)
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

-- [du] Disk Usage
function M.du(path, opts)
    opts = opts or {}
    local raw = get_raw()
    local stats = { size = 0, disk_usage = 0, files = 0, dirs = 0, seen = {} }
    
    local function recurse(p)
        local info, err = raw.get_file_info(p)
        if not info then return end
        
        -- Deduplication
        local id = string.format("%d:%s", info.vol_serial, tostring(info.file_index))
        if stats.seen[id] then return end
        stats.seen[id] = true
        
        if is_dir(info.attr) then
            stats.dirs = stats.dirs + 1
            if not is_link(info.attr) then 
                for name in scandir_native(p) do
                    recurse(p .. "\\" .. name)
                end
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

-- [find] Iterator
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
                local is_d = is_dir(attr)
                
                if is_d and opts.recursive ~= false and not is_link(attr) then
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

-- [shred] Secure Delete
function M.shred(path, opts)
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

-- [ln] Unified Link
function M.link(target, linkname, opts)
    opts = opts or {}
    local ntfs = get_ntfs()
    
    local type = "file"
    if M.is_dir(target) then type = "dir" end
    
    if opts.symbolic then
        return ntfs.mklink(linkname, target, type)
    else
        return ntfs.mklink(linkname, target, "hard")
    end
end

-- [stat]
function M.stat(path)
    local raw = get_raw()
    local info, err = raw.get_file_info(path)
    if not info then return nil, err end
    info.is_dir = is_dir(info.attr)
    info.is_link = is_link(info.attr)
    return info
end

-- [touch]
function M.touch(path)
    local h = kernel32.CreateFileW(util.to_wide(path), bit.bor(0x80000000, 0x40000000), 0, nil, 4, 0x80, nil)
    if h == ffi.cast("HANDLE", -1) then return false, util.last_error() end
    local t = ffi.new("FILETIME")
    kernel32.GetSystemTimeAsFileTime(t)
    kernel32.SetFileTime(h, nil, nil, t)
    kernel32.CloseHandle(h)
    return true
end

-- Basic Queries
function M.exists(path) return kernel32.GetFileAttributesW(util.to_wide(path)) ~= INVALID_FILE_ATTRIBUTES end
function M.is_dir(path) local a = kernel32.GetFileAttributesW(util.to_wide(path)); return a ~= -1 and is_dir(a) end
function M.is_link(path) local a = kernel32.GetFileAttributesW(util.to_wide(path)); return a ~= -1 and is_link(a) end
function M.get_version(path) return require('win-utils.fs.raw').get_version(path) end
function M.scandir(path) return scandir_native(path) end

return M