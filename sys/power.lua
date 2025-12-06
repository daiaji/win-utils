local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'

local M = {}

local function priv() 
    if not token.enable_privilege("SeShutdownPrivilege") then
        return false, "SeShutdownPrivilege required"
    end
    return true
end

function M.shutdown() 
    local ok, err = priv()
    if not ok then return false, err end
    local r = ntdll.NtShutdownSystem(2) -- PowerOff
    if r < 0 then return false, string.format("Shutdown failed: 0x%X", r) end
    return true
end

function M.reboot() 
    local ok, err = priv()
    if not ok then return false, err end
    local r = ntdll.NtShutdownSystem(1) -- Reboot
    if r < 0 then return false, string.format("Reboot failed: 0x%X", r) end
    return true
end

function M.boot_to_firmware()
    if not token.enable_privilege("SeSystemEnvironmentPrivilege") then 
        return false, "SeSystemEnvironmentPrivilege required" 
    end
    
    local name, anchor = native.to_unicode_string("OsIndications")
    local guid = ffi.new("GUID", {0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}})
    
    local buf = ffi.new("uint64_t[1]")
    local len = ffi.new("ULONG[1]", 8)
    local attr = ffi.new("ULONG[1]")
    
    local status = ntdll.NtQuerySystemEnvironmentValueEx(name, guid, buf, len, attr)
    if status == 0xC0000034 then -- Not Found
        buf[0] = 0; attr[0] = 7 
    elseif status < 0 then 
        return false, string.format("Query failed: 0x%X", status)
    end
    
    if bit.band(tonumber(buf[0]), 1) == 0 then
        buf[0] = buf[0] + 1
    end
    
    status = ntdll.NtSetSystemEnvironmentValueEx(name, guid, buf, 8, attr[0])
    local _ = anchor
    
    if status < 0 then return false, string.format("Set failed: 0x%X", status) end
    return true
end

return M