local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local class = require 'win-utils.deps'.class

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

function RegKey:read(name, opts)
    local wname = util.to_wide(name)
    local type_ptr = ffi.new("DWORD[1]")
    local size_ptr = ffi.new("DWORD[1]")
    
    if advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, nil, size_ptr) ~= 0 then return nil end
    
    local buf = ffi.new("uint8_t[?]", size_ptr[0])
    if advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, buf, size_ptr) ~= 0 then return nil end
    
    local t = type_ptr[0]
    if t == 1 or t == 2 then 
        local str = util.from_wide(ffi.cast("wchar_t*", buf))
        if str then str = str:gsub("%z+$", "") end 
        
        if t == 2 and (not opts or opts.expand ~= false) then
            local wstr = util.to_wide(str)
            local needed = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
            local ex = ffi.new("wchar_t[?]", needed)
            kernel32.ExpandEnvironmentStringsW(wstr, ex, needed)
            str = util.from_wide(ex):gsub("%z+$", "")
        end
        return str
    elseif t == 4 then 
        return ffi.cast("DWORD*", buf)[0]
    elseif t == 11 then 
        return tonumber(ffi.cast("uint64_t*", buf)[0])
    elseif t == 7 then 
        local res = {}
        local ptr = ffi.cast("wchar_t*", buf)
        local offset = 0
        while offset * 2 < size_ptr[0] do
            local s = util.from_wide(ptr + offset)
            if not s or s == "" then break end
            table.insert(res, s)
            offset = offset + #s + 1
            while (ptr+offset)[0] ~= 0 do offset = offset + 1 end
            offset = offset + 1
        end
        return res
    elseif t == 3 then 
        return ffi.string(buf, size_ptr[0])
    end
    return nil
end

local writers = {}
writers.string = function(v) local w = util.to_wide(v); return ffi.cast("uint8_t*", w), (#tostring(v)+1)*2, 1, w end
writers.dword = function(v) local d = ffi.new("DWORD[1]", v); return ffi.cast("uint8_t*", d), 4, 4, d end
writers.qword = function(v) local q = ffi.new("uint64_t[1]", v); return ffi.cast("uint8_t*", q), 8, 11, q end
writers.binary = function(v) return ffi.cast("uint8_t*", v), #v, 3, v end
writers.multi_sz = function(v)
    local total_len = 0
    local wstrs = {}
    for _, s in ipairs(v) do
        local w = util.to_wide(s)
        local len = 0; while w[len] ~= 0 do len=len+1 end; len=len+1
        table.insert(wstrs, {ptr=w, size=len*2})
        total_len = total_len + len*2
    end
    total_len = total_len + 2 
    local buf = ffi.new("uint8_t[?]", total_len)
    local offset = 0
    for _, item in ipairs(wstrs) do
        ffi.copy(buf + offset, item.ptr, item.size)
        offset = offset + item.size
    end
    return buf, total_len, 7, wstrs
end

function RegKey:write(name, val, type_str)
    if type(val) == "number" and not type_str then type_str = "dword" end
    if type(val) == "string" and not type_str then type_str = "string" end
    if type(val) == "table" and not type_str then type_str = "multi_sz" end
    
    local h = writers[type_str or "string"]
    if not h then return false end
    
    local data, size, code, anchor = h(val)
    return advapi32.RegSetValueExW(self.hkey, util.to_wide(name), 0, code, data, size) == 0
end

function RegKey:delete_value(name) 
    return advapi32.RegDeleteValueW(self.hkey, util.to_wide(name)) == 0 
end

local M = {}

function M.open_key(root, sub)
    local roots = { HKLM=0x80000002, HKCU=0x80000001, HKU=0x80000003 }
    local hKey = ffi.new("HKEY[1]")
    if advapi32.RegCreateKeyExW(ffi.cast("HKEY", roots[root] or roots.HKLM), util.to_wide(sub), 0, nil, 0, 0xF003F, nil, hKey, nil) ~= 0 then 
        return nil 
    end
    return RegKey(hKey[0])
end

function M.delete_key(root, sub, rec)
    local roots = { HKLM=0x80000002, HKCU=0x80000001, HKU=0x80000003 }
    local h = ffi.cast("HKEY", roots[root] or roots.HKLM)
    local w = util.to_wide(sub)
    if rec then 
        return advapi32.RegDeleteTreeW(h, w) == 0 
    else 
        return advapi32.RegDeleteKeyW(h, w) == 0 
    end
end

function M.save_hive(key, path)
    token.enable_privilege("SeBackupPrivilege")
    local hFile = native.open_file(path, "w", "exclusive")
    if not hFile then return false end
    local res = ntdll.NtSaveKey(key.hkey, hFile:get())
    hFile:close()
    return res >= 0
end

function M.load_hive(key_path, file_path)
    token.enable_privilege("SeRestorePrivilege")
    local oa_k, a1 = native.init_object_attributes(key_path)
    local oa_f, a2 = native.init_object_attributes(native.dos_path_to_nt_path(file_path))
    local res = ntdll.NtLoadKey(oa_k, oa_f)
    local _ = {a1, a2}
    return res == 0
end

function M.unload_hive(key_path)
    token.enable_privilege("SeRestorePrivilege")
    local oa_k, a1 = native.init_object_attributes(key_path)
    local res = ntdll.NtUnloadKey(oa_k)
    local _ = a1
    return res == 0
end

function M.with_hive(key_path, file_path, func)
    local loaded = M.load_hive(key_path, file_path)
    if not loaded then return false, "Load hive failed" end
    
    local ok, res = xpcall(function() 
        return func(key_path) 
    end, debug.traceback)
    
    collectgarbage(); collectgarbage()
    
    local unloaded = M.unload_hive(key_path)
    
    if not ok then error(res) end
    if not unloaded then return false, "Unload hive failed (Handles leaked?)" end
    
    return true, res
end

return M