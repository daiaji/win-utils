local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local class = require 'win-utils.deps'.class
local error_mod = require 'win-utils.core.error'

local RegKey = class()

function RegKey:init(hkey) self.hkey = hkey end

function RegKey:close()
    if self.hkey then 
        advapi32.RegCloseKey(self.hkey)
        self.hkey = nil 
    end
end

-- [Helper] 将 Lua 表转为 REG_MULTI_SZ 缓冲区
local function table_to_multisz(tbl)
    local parts = {}
    local total_len = 0
    for _, s in ipairs(tbl) do
        local w = util.to_wide(s)
        local len = 0; while w[len] ~= 0 do len=len+1 end; len=len+1
        table.insert(parts, {ptr=w, bytes=len*2})
        total_len = total_len + len*2
    end
    total_len = total_len + 2 
    
    local buf = ffi.new("uint8_t[?]", total_len)
    local offset = 0
    for _, item in ipairs(parts) do
        ffi.copy(buf + offset, item.ptr, item.bytes)
        offset = offset + item.bytes
    end
    return buf, total_len
end

local REG_TYPES = {
    [0] = "none",
    [1] = "string",
    [2] = "expand_sz",
    [3] = "binary",
    [4] = "dword",
    [7] = "multi_sz",
    [11] = "qword",
}

local function reg_type_name(code) return REG_TYPES[tonumber(code)] or tostring(code) end

function RegKey:read(name, opts)
    local wname = util.to_wide(name)
    local type_ptr = ffi.new("DWORD[1]")
    local size_ptr = ffi.new("DWORD[1]")
    
    -- 第一次调用：获取大小
    local res = advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, nil, size_ptr)
    if res ~= 0 then 
        -- 如果是文件未找到，返回 nil；否则返回错误信息
        if res == 2 then return nil end -- ERROR_FILE_NOT_FOUND
        return nil, error_mod.format(res) 
    end
    
    local buf = ffi.new("uint8_t[?]", size_ptr[0])
    res = advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, buf, size_ptr)
    if res ~= 0 then return nil, error_mod.format(res) end
    
    local t = type_ptr[0]
    
    -- REG_SZ / REG_EXPAND_SZ
    if t == 1 or t == 2 then 
        local str = util.from_wide(ffi.cast("wchar_t*", buf))
        if str then str = str:gsub("%z+$", "") end 
        
        if t == 2 and (not opts or opts.expand ~= false) then
            local wstr = util.to_wide(str)
            local needed = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
            if needed > 0 then
                local ex = ffi.new("wchar_t[?]", needed)
                kernel32.ExpandEnvironmentStringsW(wstr, ex, needed)
                str = util.from_wide(ex):gsub("%z+$", "")
            end
        end
        return str
    elseif t == 4 then return ffi.cast("DWORD*", buf)[0] -- REG_DWORD
    elseif t == 11 then return tonumber(ffi.cast("uint64_t*", buf)[0]) -- REG_QWORD
    elseif t == 7 then -- REG_MULTI_SZ
        local res_tbl = {}
        local ptr = ffi.cast("wchar_t*", buf)
        local offset = 0
        local max_bytes = size_ptr[0]
        while offset * 2 < max_bytes do
            local start = ptr + offset
            local len = 0
            while (offset + len) * 2 < max_bytes and start[len] ~= 0 do len = len + 1 end
            local s = util.from_wide(start, len)
            if not s or s == "" then break end
            table.insert(res_tbl, s)
            offset = offset + len + 1
        end
        return res_tbl
    elseif t == 3 then return ffi.string(buf, size_ptr[0]) -- REG_BINARY
    end
    return nil, "Unknown Type: " .. t
end

function RegKey:write(name, val, type_str)
    local wname = util.to_wide(name)
    local data, size, code
    
    if not type_str then
        if type(val) == "number" then type_str = "dword"
        elseif type(val) == "table" then type_str = "multi_sz"
        else type_str = "string" end
    end
    
    local gc_anchor
    
    if type_str == "dword" then
        local d = ffi.new("DWORD[1]", val); data = ffi.cast("uint8_t*", d); size = 4; code = 4; gc_anchor = d
    elseif type_str == "qword" then
        local q = ffi.new("uint64_t[1]", val); data = ffi.cast("uint8_t*", q); size = 8; code = 11; gc_anchor = q
    elseif type_str == "string" or type_str == "expand_sz" then
        local w = util.to_wide(tostring(val)); data = ffi.cast("uint8_t*", w)
        local len = 0; while w[len] ~= 0 do len = len + 1 end
        size = (len + 1) * 2
        code = (type_str == "expand_sz") and 2 or 1; gc_anchor = w
    elseif type_str == "multi_sz" and type(val) == "table" then
        data, size = table_to_multisz(val); code = 7
    elseif type_str == "binary" then
        data = ffi.cast("uint8_t*", val); size = #val; code = 3
    else
        return false, "Unsupported type"
    end
    
    local res = advapi32.RegSetValueExW(self.hkey, wname, 0, code, data, size)
    if res ~= 0 then return false, error_mod.format(res) end
    return true
end

function RegKey:delete_value(name) 
    local res = advapi32.RegDeleteValueW(self.hkey, util.to_wide(name))
    if res ~= 0 then return false, error_mod.format(res) end
    return true
end

function RegKey:enum_keys()
    local count = ffi.new("DWORD[1]")
    local max_len = ffi.new("DWORD[1]")
    local res = advapi32.RegQueryInfoKeyW(self.hkey, nil, nil, nil, count, max_len, nil, nil, nil, nil, nil, nil)
    if res ~= 0 then return nil, error_mod.format(res) end

    local out = {}
    local buf = ffi.new("wchar_t[?]", tonumber(max_len[0]) + 2)
    for i = 0, tonumber(count[0]) - 1 do
        local len = ffi.new("DWORD[1]", tonumber(max_len[0]) + 1)
        res = advapi32.RegEnumKeyExW(self.hkey, i, buf, len, nil, nil, nil, nil)
        if res == 0 then table.insert(out, util.from_wide(buf, tonumber(len[0])))
        elseif res ~= 259 then return nil, error_mod.format(res) end
    end
    return out
end

function RegKey:enum_values(opts)
    opts = opts or {}
    local count = ffi.new("DWORD[1]")
    local max_name = ffi.new("DWORD[1]")
    local res = advapi32.RegQueryInfoKeyW(self.hkey, nil, nil, nil, nil, nil, nil, count, max_name, nil, nil, nil)
    if res ~= 0 then return nil, error_mod.format(res) end

    local out = {}
    local name_buf = ffi.new("wchar_t[?]", tonumber(max_name[0]) + 2)
    for i = 0, tonumber(count[0]) - 1 do
        local name_len = ffi.new("DWORD[1]", tonumber(max_name[0]) + 1)
        local type_ptr = ffi.new("DWORD[1]")
        res = advapi32.RegEnumValueW(self.hkey, i, name_buf, name_len, nil, type_ptr, nil, nil)
        if res == 0 then
            local name = util.from_wide(name_buf, tonumber(name_len[0]))
            local item = { name = name, type = reg_type_name(type_ptr[0]), type_code = tonumber(type_ptr[0]) }
            if opts.read ~= false then item.value = self:read(name, { expand = opts.expand }) end
            table.insert(out, item)
        elseif res ~= 259 then return nil, error_mod.format(res) end
    end
    return out
end

local M = {}

local ROOTS = { HKLM=0x80000002, HKCU=0x80000001, HKU=0x80000003, HKCR=0x80000000, HKCC=0x80000005 }

local function root_handle(root)
    if type(root) == "cdata" then return root end
    return ffi.cast("HKEY", ROOTS[root] or ROOTS.HKLM)
end

local sub_modules = {
    acl = 'win-utils.reg.acl'
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

function M.open_key(root, sub)
    local hKey = ffi.new("HKEY[1]")
    local wsub = util.to_wide(sub)
    
    local res = advapi32.RegCreateKeyExW(root_handle(root), wsub, 0, nil, 0, 0xF003F, nil, hKey, nil)
    if res ~= 0 then return nil, error_mod.format(res) end
    return RegKey(hKey[0])
end

function M.create_key(root, sub) return M.open_key(root, sub) end

function M.open_existing_key(root, sub, access)
    local hKey = ffi.new("HKEY[1]")
    local res = advapi32.RegOpenKeyExW(root_handle(root), util.to_wide(sub), 0, access or 0x20019, hKey)
    if res ~= 0 then return nil, error_mod.format(res) end
    return RegKey(hKey[0])
end

function M.delete_key(root, sub, rec)
    local h = root_handle(root)
    local w = util.to_wide(sub)
    local res
    if rec then res = advapi32.RegDeleteTreeW(h, w)
    else res = advapi32.RegDeleteKeyW(h, w) end
    
    if res ~= 0 then return false, error_mod.format(res) end
    return true
end

local function reg_escape(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function hex_bytes(s)
    local out = {}
    for i = 1, #s do out[#out + 1] = string.format("%02x", s:byte(i)) end
    return table.concat(out, ",")
end

local function value_to_reg_line(item)
    local name = item.name == "" and "@" or string.format('"%s"', reg_escape(item.name))
    if item.type == "string" then return string.format('%s="%s"', name, reg_escape(item.value or "")) end
    if item.type == "expand_sz" then
        local data = util.to_wide(item.value or "")
        local len = 0; while data[len] ~= 0 do len = len + 1 end; len = len + 1
        return string.format('%s=hex(2):%s', name, hex_bytes(ffi.string(ffi.cast("char*", data), len * 2)))
    end
    if item.type == "multi_sz" then
        local data, size = table_to_multisz(item.value or {})
        return string.format('%s=hex(7):%s', name, hex_bytes(ffi.string(data, size)))
    end
    if item.type == "dword" then return string.format('%s=dword:%08x', name, tonumber(item.value or 0)) end
    if item.type == "qword" then
        local q = ffi.new("uint64_t[1]", item.value or 0)
        return string.format('%s=hex(b):%s', name, hex_bytes(ffi.string(ffi.cast("char*", q), 8)))
    end
    if item.type == "binary" then return string.format('%s=hex:%s', name, hex_bytes(item.value or "")) end
    return nil
end

local function to_utf16le_bytes(s)
    local w = util.to_wide(s)
    local len = 0; while w[len] ~= 0 do len = len + 1 end
    return "\255\254" .. ffi.string(ffi.cast("char*", w), len * 2)
end

function M.export(root, sub, path, opts)
    opts = opts or {}
    local lines = { "Windows Registry Editor Version 5.00", "" }

    local function walk(root_name, sub_path)
        local key, err = M.open_existing_key(root_name, sub_path)
        if not key then return false, err end
        lines[#lines + 1] = string.format("[%s\\%s]", root_name, sub_path)
        local values, values_err = key:enum_values({ expand = false })
        if not values then key:close(); return false, values_err end
        for _, item in ipairs(values) do
            local line = value_to_reg_line(item)
            if line then lines[#lines + 1] = line end
        end
        lines[#lines + 1] = ""

        if opts.recursive ~= false then
            local keys, keys_err = key:enum_keys()
            if not keys then key:close(); return false, keys_err end
            key:close()
            for _, child in ipairs(keys) do
                local ok, child_err = walk(root_name, sub_path .. "\\" .. child)
                if not ok then return false, child_err end
            end
        else
            key:close()
        end
        return true
    end

    local ok, err = walk(root, sub)
    if not ok then return false, err end
    local f, open_err = io.open(path, "wb")
    if not f then return false, open_err end
    f:write(to_utf16le_bytes(table.concat(lines, "\r\n") .. "\r\n"))
    f:close()
    return true
end

function M.import_file(path, opts)
    opts = opts or {}
    if not path or path == "" then return nil, "path required" end
    if opts.dry_run then
        return { ok = true, dry_run = true, command = "reg.exe import " .. tostring(path) }
    end

    local proc = require 'win-utils.process.init'
    local result, err = proc.exec({
        file = "reg.exe",
        args = { "import", path },
        show = 0,
        capture_stdout = true,
        capture_stderr = true,
        timeout = opts.timeout or 30000,
    })
    if not result then return nil, err end
    if result.exit_code ~= 0 then
        return nil, result.stderr ~= "" and result.stderr or result.stdout
    end
    return result
end

function M.save_hive(key, path)
    token.enable_privilege("SeBackupPrivilege")
    local hFile, err = native.open_file(path, "w", "exclusive")
    if not hFile then return false, err end
    
    local res = ntdll.NtSaveKey(key.hkey, hFile:get())
    hFile:close()
    
    if res < 0 then return false, string.format("NtSaveKey Failed: 0x%X", res) end
    return true
end

function M.load_hive(key_path, file_path, as_volatile)
    token.enable_privilege("SeRestorePrivilege")
    local oa_k, anchor1 = native.init_object_attributes(key_path)
    local oa_f, anchor2 = native.init_object_attributes(native.dos_path_to_nt_path(file_path))
    
    local res
    if as_volatile then
        res = ntdll.NtLoadKeyEx(oa_k, oa_f, 0x1, nil, nil, 0, nil, nil)
    else
        res = ntdll.NtLoadKey(oa_k, oa_f)
    end
    
    local _ = {anchor1, anchor2}
    if res < 0 then return false, string.format("NtLoadKey Failed: 0x%X", res) end
    return true
end

function M.unload_hive(key_path)
    token.enable_privilege("SeRestorePrivilege")
    local oa_k, anchor = native.init_object_attributes(key_path)
    local res = ntdll.NtUnloadKey(oa_k)
    local _ = anchor
    if res < 0 then return false, string.format("NtUnloadKey Failed: 0x%X", res) end
    return true
end

function M.with_hive(key_path, file_path, func)
    local loaded, err = M.load_hive(key_path, file_path)
    if not loaded then return false, "Load hive failed: " .. tostring(err) end
    
    local result_ok, result_val
    local func_ok, err = xpcall(function() return func(key_path) end, debug.traceback)
    
    if not func_ok then
        result_ok = false; result_val = err
    else
        result_ok = true; result_val = func_ok
    end
    
    collectgarbage(); collectgarbage()
    
    local attempts = 0
    ::retry_unload::
    if not M.unload_hive(key_path) then
        attempts = attempts + 1
        if attempts < 3 then
            kernel32.Sleep(100)
            collectgarbage()
            goto retry_unload
        end
        return false, "Unload hive failed (Hive locked?)"
    end
    
    if not result_ok then error(result_val) end
    return true, result_val
end

return M
