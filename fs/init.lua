local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local version = require 'ffi.req' 'Windows.sdk.version'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'

local M = {}

-- [Lazy Loading Submodules]
local sub_modules = {
    native = 'win-utils.fs.raw',
    ntfs   = 'win-utils.fs.ntfs',
    path   = 'win-utils.fs.path'
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

-- Native Directory Information Struct
ffi.cdef[[
    typedef struct _FILE_DIRECTORY_INFORMATION {
        ULONG NextEntryOffset;
        ULONG FileIndex;
        LARGE_INTEGER CreationTime;
        LARGE_INTEGER LastAccessTime;
        LARGE_INTEGER LastWriteTime;
        LARGE_INTEGER ChangeTime;
        LARGE_INTEGER EndOfFile;
        LARGE_INTEGER AllocationSize;
        ULONG FileAttributes;
        ULONG FileNameLength;
        WCHAR FileName[1];
    } FILE_DIRECTORY_INFORMATION;
]]

-- [Internal] Native Directory Iterator
local function scandir_native(path)
    -- Lazy require
    local raw = require 'win-utils.fs.raw'
    local h, err = raw.open_file(path, "r", true) 
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
                local is_dir = bit.band(info.FileAttributes, 0x10) ~= 0
                
                if info.NextEntryOffset == 0 then current_ptr = nil
                else current_ptr = current_ptr + info.NextEntryOffset end
                
                if name ~= "." and name ~= ".." then return name, is_dir end
            else
                local status = ntdll.NtQueryDirectoryFile(h:get(), nil, nil, nil, io, buf, buf_size, 1, false, nil, first_call)
                first_call = false
                if status < 0 then h:close(); done = true; return nil end
                current_ptr = buf
            end
        end
    end
end

-- [Internal] Recursive Delete
local function rm_rf(path)
    local raw = require 'win-utils.fs.raw'
    -- 1. Try POSIX delete first
    if raw.delete_posix(path) then return true end
    
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    if attr == 0xFFFFFFFF then return true end
    
    if bit.band(attr, 0x10) ~= 0 then -- Directory
        local ok = true
        for name, is_dir in scandir_native(path) do
            local sub = path .. "\\" .. name
            if is_dir then 
                if not rm_rf(sub) then ok = false end
            else 
                if not raw.delete_posix(sub) then ok = false end 
            end
        end
        
        if ok then
            -- Remove ReadOnly if present before deleting dir
            if bit.band(attr, 1) ~= 0 then raw.set_attributes(path, 0x80) end
            return kernel32.RemoveDirectoryW(util.to_wide(path)) ~= 0
        end
        return false
    end
    
    -- File fallback
    if bit.band(attr, 1) ~= 0 then raw.set_attributes(path, 0x80) end
    return kernel32.DeleteFileW(util.to_wide(path)) ~= 0
end

-- [Internal] Recursive Copy
local function cp_r(src, dst, fail_on_exist)
    local attr = kernel32.GetFileAttributesW(util.to_wide(src))
    if attr == 0xFFFFFFFF then return false, "Source not found" end
    
    if bit.band(attr, 0x10) == 0 then -- File
        return kernel32.CopyFileW(util.to_wide(src), util.to_wide(dst), fail_on_exist and 1 or 0) ~= 0
    else -- Directory
        if kernel32.CreateDirectoryW(util.to_wide(dst), nil) == 0 then
            if kernel32.GetLastError() ~= 183 then return false, "CreateDir failed" end
        end
        for name, is_dir in scandir_native(src) do
            if not cp_r(src .. "\\" .. name, dst .. "\\" .. name, fail_on_exist) then return false, "Copy failed: " .. name end
        end
        return true
    end
end

-- [API Exports]
function M.copy(src, dst) return cp_r(src, dst, false) end
function M.move(src, dst) return kernel32.MoveFileExW(util.to_wide(src), util.to_wide(dst), 11) ~= 0 end
function M.delete(path) return rm_rf(path) end
M.force_delete = M.delete

function M.recycle(path)
    -- Recycle bin logic (Shell32)
    -- In PE, usually fails or Shell32 is missing
    local sh = ffi.load("shell32")
    if not sh then return false, "Recycle bin not available" end
    local op = ffi.new("SHFILEOPSTRUCTW")
    op.wFunc = 3; op.pFrom = util.to_wide(path.."\0"); op.fFlags = 0x454
    return sh.SHFileOperationW(op) == 0
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
    return string.format("%d.%d.%d.%d", bit.rshift(v.dwFileVersionMS, 16), bit.band(v.dwFileVersionMS, 0xFFFF), bit.rshift(v.dwFileVersionLS, 16), bit.band(v.dwFileVersionLS, 0xFFFF))
end

function M.exists(path) return kernel32.GetFileAttributesW(util.to_wide(path)) ~= 0xFFFFFFFF end
function M.is_dir(path)
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    return a ~= 0xFFFFFFFF and bit.band(a, 0x10) ~= 0
end

return M