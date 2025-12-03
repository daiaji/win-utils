local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local native = require 'win-utils.native'
local token = require 'win-utils.process.token'

local C = ffi.C

local RegKey = {}
RegKey.__index = RegKey

function RegKey:read(value_name, options)
    local lpValue = util.to_wide(value_name)
    local type_ptr = ffi.new("DWORD[1]")
    local size_ptr = ffi.new("DWORD[1]")

    local res = advapi32.RegQueryValueExW(self.hkey, lpValue, nil, type_ptr, nil, size_ptr)
    if res ~= 0 then return nil, "RegQueryValueExW size failed: " .. res end

    local buf = ffi.new("uint8_t[?]", size_ptr[0])
    res = advapi32.RegQueryValueExW(self.hkey, lpValue, nil, type_ptr, buf, size_ptr)
    if res ~= 0 then return nil, "RegQueryValueExW data failed" end

    local t = type_ptr[0]

    if t == C.REG_SZ or t == C.REG_EXPAND_SZ then
        local char_count = size_ptr[0] / 2
        local val = util.from_wide(ffi.cast("wchar_t*", buf), char_count)

        if val then val = val:gsub("%z+$", "") end

        if t == C.REG_EXPAND_SZ and (not options or options.expand ~= false) then
            local wstr = util.to_wide(val)
            local needed = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
            if needed > 0 then
                local exbuf = ffi.new("wchar_t[?]", needed)
                kernel32.ExpandEnvironmentStringsW(wstr, exbuf, needed)
                val = util.from_wide(exbuf) 
                if val then val = val:gsub("%z+$", "") end
            end
        end
        return val
    elseif t == C.REG_DWORD or t == C.REG_DWORD_BIG_ENDIAN then
        return ffi.cast("DWORD*", buf)[0]
    elseif t == C.REG_BINARY then
        if options and options.hex then
            local bin = ffi.string(buf, size_ptr[0])
            return (bin:gsub(".", function(c) return string.format("%02X ", string.byte(c)) end))
        end
        return ffi.string(buf, size_ptr[0])
    elseif t == C.REG_QWORD then
        return tonumber(ffi.cast("uint64_t*", buf)[0])
    elseif t == C.REG_MULTI_SZ then
        local res_tab = {}
        local wptr = ffi.cast("wchar_t*", buf)
        local offset = 0
        local max_bytes = size_ptr[0]
        while offset * 2 < max_bytes do
            local str = util.from_wide(wptr + offset)
            if str == "" then break end
            table.insert(res_tab, str)
            local wlen = 0
            while (wptr + offset)[wlen] ~= 0 do wlen = wlen + 1 end
            offset = offset + wlen + 1
        end
        return res_tab
    end

    return nil, "Unsupported type: " .. t
end

-- Dispatch table for write operations
-- [FIX] Handlers now return the 'anchor' object (4th return value)
-- to ensure the cdata stays alive in the calling scope.
local write_handlers = {}

write_handlers["string"] = function(v)
    local wval = util.to_wide(tostring(v))
    local wlen = 0
    while wval[wlen] ~= 0 do wlen = wlen + 1 end
    wlen = wlen + 1
    -- Return: pointer, size, type, ANCHOR
    return ffi.cast("const uint8_t*", wval), wlen * 2, C.REG_SZ, wval
end
write_handlers["REG_SZ"] = write_handlers["string"]

write_handlers["dword"] = function(v)
    local tmp = ffi.new("DWORD[1]", v)
    return ffi.cast("const uint8_t*", tmp), 4, C.REG_DWORD, tmp
end
write_handlers["REG_DWORD"] = write_handlers["dword"]

write_handlers["qword"] = function(v)
    local tmp = ffi.new("uint64_t[1]", v)
    return ffi.cast("const uint8_t*", tmp), 8, C.REG_QWORD, tmp
end

write_handlers["binary"] = function(v)
    -- Lua strings are safe to cast if held in 'v'
    return ffi.cast("const uint8_t*", v), #v, C.REG_BINARY, v
end

write_handlers["multi_sz"] = function(v)
    local blob = {}
    local CP_UTF8 = 65001

    for _, str_item in ipairs(v) do
        local str = tostring(str_item)
        local wlen = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, -1, nil, 0)
        local wbuf = ffi.new("wchar_t[?]", wlen)
        kernel32.MultiByteToWideChar(CP_UTF8, 0, str, -1, wbuf, wlen)
        table.insert(blob, ffi.string(ffi.cast("char*", wbuf), wlen * 2))
    end

    table.insert(blob, "\0\0")
    local raw_data = table.concat(blob)
    return ffi.cast("const uint8_t*", raw_data), #raw_data, C.REG_MULTI_SZ, raw_data
end
write_handlers["REG_MULTI_SZ"] = write_handlers["multi_sz"]

function RegKey:write(value_name, value, type_str)
    local lpValue = util.to_wide(value_name)

    if not type_str then
        if type(value) == "number" then
            type_str = "dword"
        elseif type(value) == "string" then
            type_str = "string"
        elseif type(value) == "table" then
            type_str = "multi_sz"
        end
    end

    local handler = write_handlers[type_str]
    if not handler then return nil, "Unsupported type for write" end

    -- [FIX] Capture the anchor variable to prevent GC
    local data, size, dwType, anchor = handler(value)

    if advapi32.RegSetValueExW(self.hkey, lpValue, 0, dwType, data, size) ~= 0 then
        return false, "RegSetValueExW failed"
    end
    
    -- anchor stays alive until here
    return true
end

function RegKey:delete_value(name)
    if advapi32.RegDeleteValueW(self.hkey, util.to_wide(name)) ~= 0 then return false end
    return true
end

function RegKey:close()
    if self.hkey then
        advapi32.RegCloseKey(self.hkey)
        self.hkey = nil
    end
end

function RegKey:__gc() self:close() end

local M = {}

local function recurse_delete(hPar, subStr)
    local hChild = ffi.new("HKEY[1]")
    if advapi32.RegOpenKeyExW(hPar, subStr, 0, 0xF003F, hChild) ~= 0 then return end

    local name = ffi.new("wchar_t[256]")
    while true do
        local len = ffi.new("DWORD[1]", 256)
        if advapi32.RegEnumKeyExW(hChild[0], 0, name, len, nil, nil, nil, nil) ~= 0 then break end
        recurse_delete(hChild[0], name)
    end
    advapi32.RegCloseKey(hChild[0])
    advapi32.RegDeleteKeyW(hPar, subStr)
end

function M.open_key(root_str, sub_str)
    local roots = { HKLM = 0x80000002, HKCU = 0x80000001 }
    local hRoot = ffi.cast("HKEY", roots[root_str] or roots.HKCU)
    local hKey = ffi.new("HKEY[1]")
    if advapi32.RegOpenKeyExW(hRoot, util.to_wide(sub_str), 0, 0xF003F, hKey) ~= 0 then return nil end
    return setmetatable({ hkey = hKey[0] }, RegKey)
end

function M.delete_key(root_str, sub_str, recursive)
    local roots = { HKLM = 0x80000002, HKCU = 0x80000001 }
    local hRoot = ffi.cast("HKEY", roots[root_str] or roots.HKCU)
    local wSub = util.to_wide(sub_str)
    if recursive then
        recurse_delete(hRoot, wSub)
        return true
    else
        return advapi32.RegDeleteKeyW(hRoot, wSub) == 0
    end
end

-- [NEW] Native Hive Operations
-- Requires SeRestorePrivilege/SeBackupPrivilege

-- Load a registry hive from a file
-- @param key_path: Target registry key (e.g. "\\Registry\\Machine\\PE_SYSTEM")
-- @param file_path: Source file (DOS path, e.g. "C:\\Windows\\System32\\Config\\SYSTEM")
-- @param as_volatile: Load as volatile (memory only, not saved on unload)
function M.load_hive(key_path, file_path, as_volatile)
    token.enable_privilege("SeRestorePrivilege")
    
    local nt_file_path = native.dos_path_to_nt_path(file_path)
    
    local oa_key, anchor_key = native.init_object_attributes(key_path, nil, C.OBJ_CASE_INSENSITIVE)
    local oa_file, anchor_file = native.init_object_attributes(nt_file_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local flags = 0
    if as_volatile then
        -- REG_NO_LAZY_FLUSH | REG_WHOLE_HIVE_VOLATILE ?
        -- SystemInformer uses specific flags, here we support basic or volatile.
        -- REG_WHOLE_HIVE_VOLATILE = 0x00000001L
        flags = 0x00000001
    end
    
    -- NtLoadKeyEx(Target, Source, Flags, Trust, Event, Access, RootHandle, Reserved)
    -- We use NtLoadKey if no flags, else NtLoadKeyEx
    local status
    if flags == 0 then
        status = ntdll.NtLoadKey(oa_key, oa_file)
    else
        status = ntdll.NtLoadKeyEx(oa_key, oa_file, flags, nil, nil, 0, nil, nil)
    end
    
    -- Keep alive
    local _ = { anchor_key, anchor_file }
    
    if status < 0 then return false, string.format("NtLoadKey failed: 0x%X", status) end
    return true
end

-- Unload a registry hive
-- @param key_path: Target registry key (e.g. "\\Registry\\Machine\\PE_SYSTEM")
function M.unload_hive(key_path)
    token.enable_privilege("SeRestorePrivilege")
    
    local oa_key, anchor_key = native.init_object_attributes(key_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtUnloadKey(oa_key)
    
    local _ = anchor_key
    
    if status < 0 then return false, string.format("NtUnloadKey failed: 0x%X", status) end
    return true
end

-- Save a registry key to a hive file
-- @param key_handle: Handle to open key (must be valid)
-- @param file_path: Target file (DOS path)
function M.save_hive(key_handle, file_path)
    token.enable_privilege("SeBackupPrivilege")
    
    local nt_file_path = native.dos_path_to_nt_path(file_path)
    
    -- NtSaveKey requires a FILE HANDLE, not a path.
    -- We must create the file first with native NtCreateFile or CreateFileW
    
    local hFile = kernel32.CreateFileW(util.to_wide(file_path), 
        bit.bor(C.GENERIC_READ, C.GENERIC_WRITE), 
        0, -- No share
        nil, 
        C.CREATE_ALWAYS, 
        C.FILE_ATTRIBUTE_NORMAL, 
        nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, "CreateFile failed: " .. util.format_error() end
    
    local status = ntdll.NtSaveKey(ffi.cast("HANDLE", key_handle), hFile)
    
    kernel32.CloseHandle(hFile)
    
    if status < 0 then return false, string.format("NtSaveKey failed: 0x%X", status) end
    return true
end

return M