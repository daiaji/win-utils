local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

-- [FIX] minwindef already defines these constants via ffi.C,
-- but we can use local aliases for clarity if needed, or just rely on ffi.C.
-- For safety and performance in LuaJIT, local consts are fine,
-- but let's align with the bindings.
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

    -- [CHANGED] Use Constants from minwindef (ffi.C)
    if t == C.REG_SZ or t == C.REG_EXPAND_SZ then
        -- [FIX] Use explicit length to safety read buffer
        -- size_ptr is bytes, wchar_t is 2 bytes
        local char_count = size_ptr[0] / 2
        local val = util.from_wide(ffi.cast("wchar_t*", buf), char_count)

        -- Remove trailing nulls which are typically included in REG_SZ
        if val then val = val:gsub("%z+$", "") end

        if t == C.REG_EXPAND_SZ and (not options or options.expand ~= false) then
            -- For expand, we need to convert back to wide, expand, and back to multi
            -- This is slightly inefficient but safe.
            local wstr = util.to_wide(val)
            local needed = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
            if needed > 0 then
                local exbuf = ffi.new("wchar_t[?]", needed)
                kernel32.ExpandEnvironmentStringsW(wstr, exbuf, needed)
                val = util.from_wide(exbuf) -- implicit -1 is fine here as API guarantees null term
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
            -- [FIX] from_wide default behavior (-1) reads until null, which is correct for MULTI_SZ parts
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
local write_handlers = {}

write_handlers["string"] = function(v)
    local wval = util.to_wide(tostring(v))
    local wlen = 0
    while wval[wlen] ~= 0 do wlen = wlen + 1 end
    wlen = wlen + 1
    return ffi.cast("const uint8_t*", wval), wlen * 2, C.REG_SZ
end
write_handlers["REG_SZ"] = write_handlers["string"]

write_handlers["dword"] = function(v)
    local tmp = ffi.new("DWORD[1]", v)
    return ffi.cast("const uint8_t*", tmp), 4, C.REG_DWORD
end
write_handlers["REG_DWORD"] = write_handlers["dword"]

write_handlers["qword"] = function(v)
    local tmp = ffi.new("uint64_t[1]", v)
    return ffi.cast("const uint8_t*", tmp), 8, C.REG_QWORD
end

write_handlers["binary"] = function(v)
    return ffi.cast("const uint8_t*", v), #v, C.REG_BINARY
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
    return ffi.cast("const uint8_t*", raw_data), #raw_data, C.REG_MULTI_SZ
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

    local data, size, dwType = handler(value)

    if advapi32.RegSetValueExW(self.hkey, lpValue, 0, dwType, data, size) ~= 0 then
        return false, "RegSetValueExW failed"
    end
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

return M
