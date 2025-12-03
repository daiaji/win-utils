local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local native = require 'win-utils.native'
local token = require 'win-utils.process.token'
local class = require 'win-utils.deps'.class

-- Vista+ API
ffi.cdef [[ LONG RegDeleteTreeW(HKEY hKey, LPCWSTR lpSubKey); ]]

local C = ffi.C
local RegKey = class()

function RegKey:init(hkey)
    self.hkey = hkey
end

function RegKey:close()
    if self.hkey then
        advapi32.RegCloseKey(self.hkey)
        self.hkey = nil
    end
end

function RegKey:__gc()
    self:close()
end

function RegKey:read(value_name, options)
    local lpValue = util.to_wide(value_name)
    local type_ptr = ffi.new("DWORD[1]")
    local size_ptr = ffi.new("DWORD[1]")

    -- 第一次调用获取长度
    local res = advapi32.RegQueryValueExW(self.hkey, lpValue, nil, type_ptr, nil, size_ptr)
    if res ~= 0 then return nil end

    local buf = ffi.new("uint8_t[?]", size_ptr[0])
    -- 第二次调用获取数据
    res = advapi32.RegQueryValueExW(self.hkey, lpValue, nil, type_ptr, buf, size_ptr)
    if res ~= 0 then return nil end

    local t = type_ptr[0]

    if t == C.REG_SZ or t == C.REG_EXPAND_SZ then
        local char_count = size_ptr[0] / 2
        local val = util.from_wide(ffi.cast("wchar_t*", buf), char_count)
        if val then val = val:gsub("%z+$", "") end -- 去除尾部可能的空字符

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
            if not str or str == "" then break end
            table.insert(res_tab, str)
            local wlen = 0
            while (wptr + offset)[wlen] ~= 0 do wlen = wlen + 1 end
            offset = offset + wlen + 1
        end
        return res_tab
    end

    return nil, "Unsupported type: " .. t
end

-- 写入处理分发
local write_handlers = {}

write_handlers["string"] = function(v)
    local wval = util.to_wide(tostring(v))
    local wlen = 0
    while wval[wlen] ~= 0 do wlen = wlen + 1 end
    return ffi.cast("const uint8_t*", wval), (wlen + 1) * 2, C.REG_SZ, wval
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
    return ffi.cast("const uint8_t*", v), #v, C.REG_BINARY, v
end

write_handlers["multi_sz"] = function(v)
    local blob = {}
    for _, str_item in ipairs(v) do
        local str = tostring(str_item)
        local w = util.to_wide(str)
        local len = 0
        while w[len] ~= 0 do len = len + 1 end
        table.insert(blob, ffi.string(ffi.cast("char*", w), (len + 1) * 2))
    end
    table.insert(blob, "\0\0")
    local data = table.concat(blob)
    return ffi.cast("const uint8_t*", data), #data, C.REG_MULTI_SZ, data
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

    local data, size, dwType, anchor = handler(value)

    if advapi32.RegSetValueExW(self.hkey, lpValue, 0, dwType, data, size) ~= 0 then
        return false, "RegSetValueExW failed"
    end
    
    return true
end

function RegKey:delete_value(name)
    return advapi32.RegDeleteValueW(self.hkey, util.to_wide(name)) == 0
end

local M = {}

function M.open_key(root_str, sub_str)
    local roots = { HKLM = 0x80000002, HKCU = 0x80000001 }
    local hRoot = ffi.cast("HKEY", roots[root_str] or roots.HKCU)
    local hKey = ffi.new("HKEY[1]")
    if advapi32.RegOpenKeyExW(hRoot, util.to_wide(sub_str), 0, 0xF003F, hKey) ~= 0 then return nil end
    return RegKey(hKey[0])
end

function M.delete_key(root_str, sub_str, recursive)
    local roots = { HKLM = 0x80000002, HKCU = 0x80000001 }
    local hRoot = ffi.cast("HKEY", roots[root_str] or roots.HKCU)
    local wSub = util.to_wide(sub_str)
    if recursive then
        return advapi32.RegDeleteTreeW(hRoot, wSub) == 0
    else
        return advapi32.RegDeleteKeyW(hRoot, wSub) == 0
    end
end

-- Native Hive Operations
function M.load_hive(key_path, file_path, as_volatile)
    token.enable_privilege("SeRestorePrivilege")
    
    local nt_file_path = native.dos_path_to_nt_path(file_path)
    local oa_key, anchor_key = native.init_object_attributes(key_path, nil, C.OBJ_CASE_INSENSITIVE)
    local oa_file, anchor_file = native.init_object_attributes(nt_file_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local flags = as_volatile and 0x00000001 or 0
    local status
    if flags == 0 then
        status = ntdll.NtLoadKey(oa_key, oa_file)
    else
        status = ntdll.NtLoadKeyEx(oa_key, oa_file, flags, nil, nil, 0, nil, nil)
    end
    
    local _ = {anchor_key, anchor_file}
    
    if status < 0 then return false, string.format("NtLoadKey failed: 0x%X", status) end
    return true
end

function M.unload_hive(key_path)
    token.enable_privilege("SeRestorePrivilege")
    local oa_key, anchor = native.init_object_attributes(key_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtUnloadKey(oa_key)
    local _ = anchor
    
    if status < 0 then return false, string.format("NtUnloadKey failed: 0x%X", status) end
    return true
end

function M.save_hive(key_handle, file_path)
    token.enable_privilege("SeBackupPrivilege")
    
    local hFile = kernel32.CreateFileW(util.to_wide(file_path), 
        bit.bor(C.GENERIC_READ, C.GENERIC_WRITE), 
        0, nil, C.CREATE_ALWAYS, C.FILE_ATTRIBUTE_NORMAL, nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, "CreateFile failed: " .. util.format_error() end
    
    local status = ntdll.NtSaveKey(ffi.cast("HANDLE", key_handle), hFile)
    kernel32.CloseHandle(hFile)
    
    if status < 0 then return false, string.format("NtSaveKey failed: 0x%X", status) end
    return true
end

return M