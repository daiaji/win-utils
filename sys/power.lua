local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'

local M = {}

local function priv() token.enable_privilege("SeShutdownPrivilege") end

function M.shutdown() priv(); ntdll.NtShutdownSystem(2) end -- ShutdownPowerOff
function M.reboot() priv(); ntdll.NtShutdownSystem(1) end   -- ShutdownReboot

-- [Restored] 重启进入 UEFI 设置
function M.boot_to_firmware()
    token.enable_privilege("SeSystemEnvironmentPrivilege")
    
    local name, anchor = native.to_unicode_string("OsIndications")
    local guid = ffi.new("GUID", {0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}})
    
    local buf = ffi.new("uint64_t[1]")
    local len = ffi.new("ULONG[1]", 8)
    local attr = ffi.new("ULONG[1]")
    
    -- 1. Read current value
    local status = ntdll.NtQuerySystemEnvironmentValueEx(name, guid, buf, len, attr)
    
    -- 0xC0000034 = STATUS_VARIABLE_NOT_FOUND
    if status == 0xC0000034 then 
        buf[0] = 0
        attr[0] = 7 -- NON_VOLATILE | BOOTSERVICE | RUNTIME
    elseif status < 0 then 
        return false, "Query failed" 
    end
    
    -- 2. Set Bit 0 (EFI_OS_INDICATIONS_BOOT_TO_FW_UI)
    -- LuaJIT bit op is 32-bit, manual int64 manipulation required or simple addition if low bit is 0
    if bit.band(tonumber(buf[0]), 1) == 0 then
        buf[0] = buf[0] + 1
    end
    
    status = ntdll.NtSetSystemEnvironmentValueEx(name, guid, buf, 8, attr[0])
    
    -- keep anchor alive
    local _ = anchor
    return status >= 0
end

return M