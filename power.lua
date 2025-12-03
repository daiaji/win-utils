local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local token = require 'win-utils.process.token'
local native = require 'win-utils.native'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- Native Power Action Helpers
local function initiate_power_action(action, flags)
    -- Enable SeShutdownPrivilege
    if not token.enable_privilege("SeShutdownPrivilege") then
        return false, "Failed to enable SeShutdownPrivilege"
    end
    
    -- NtInitiatePowerAction(Action, LightestState, Flags, Asynchronous)
    local status = ntdll.NtInitiatePowerAction(
        action, 
        C.PowerSystemSleeping1, -- LightestSystemState (Generic choice)
        flags, 
        false -- Synchronous? Usually true for scripts, but async allows return.
    )
    
    if status < 0 then
        return false, string.format("NtInitiatePowerAction failed: 0x%X", status)
    end
    return true
end

local function shutdown_system(action)
    -- Enable SeShutdownPrivilege
    if not token.enable_privilege("SeShutdownPrivilege") then
        return false, "Failed to enable SeShutdownPrivilege"
    end
    
    local status = ntdll.NtShutdownSystem(action)
    
    if status < 0 then
        return false, string.format("NtShutdownSystem failed: 0x%X", status)
    end
    return true
end

-- Standard Shutdown
-- @param force: Force apps to close
function M.shutdown(force)
    local flags = C.POWER_ACTION_QUERY_ALLOWED or 1
    if force then 
        flags = bit.bor(flags, C.POWER_ACTION_CRITICAL or 0x80000000)
    end
    return initiate_power_action(C.PowerActionShutdown, flags)
end

-- Standard Reboot
function M.reboot(force)
    local flags = C.POWER_ACTION_QUERY_ALLOWED or 1
    if force then 
        flags = bit.bor(flags, C.POWER_ACTION_CRITICAL or 0x80000000)
    end
    return initiate_power_action(C.PowerActionShutdownReset, flags)
end

-- Hard/Fast Shutdown (Skip some notifications)
function M.fast_shutdown()
    return shutdown_system(C.ShutdownPowerOff)
end

-- Hard/Fast Reboot
function M.fast_reboot()
    return shutdown_system(C.ShutdownReboot)
end

-- Sleep / Suspend
function M.suspend()
    return initiate_power_action(C.PowerActionSleep, C.POWER_ACTION_QUERY_ALLOWED or 1)
end

-- Hibernate
function M.hibernate()
    return initiate_power_action(C.PowerActionHibernate, C.POWER_ACTION_QUERY_ALLOWED or 1)
end

-- [NEW] Boot to Firmware (UEFI BIOS)
-- Sets the OSIndications UEFI variable to request booting into Firmware UI on next reboot
function M.boot_to_firmware()
    -- 1. Enable Privilege
    if not token.enable_privilege("SeSystemEnvironmentPrivilege") then
        return false, "Failed to enable SeSystemEnvironmentPrivilege (Administrator required)"
    end
    
    -- EFI_GLOBAL_VARIABLE {8BE4DF61-93CA-11D2-AA0D-00E098032B8C}
    local efi_guid = ffi.new("GUID", {0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}})
    
    -- Variable Names
    local var_supported, anchor1 = native.to_unicode_string("OsIndicationsSupported")
    local var_indications, anchor2 = native.to_unicode_string("OsIndications")
    
    -- 2. Check if BootToFwUI is supported
    -- EFI_OS_INDICATIONS_BOOT_TO_FW_UI = 0x0000000000000001ULL
    
    local buf = ffi.new("uint64_t[1]")
    local len = ffi.new("ULONG[1]", 8)
    local attr = ffi.new("ULONG[1]")
    
    local status = ntdll.NtQuerySystemEnvironmentValueEx(var_supported, efi_guid, buf, len, nil)
    
    -- Keep anchors alive
    local _ = {anchor1, anchor2}
    
    if status < 0 then
        if status == 0xC0000034 then return false, "UEFI not supported (OsIndicationsSupported not found)" end
        return false, string.format("Query OsIndicationsSupported failed: 0x%X", status)
    end
    
    -- Check Bit 0
    if bit.band(tonumber(buf[0]), 1) == 0 then
        return false, "Firmware does not support BootToFwUI"
    end
    
    -- 3. Get current OsIndications
    len[0] = 8
    status = ntdll.NtQuerySystemEnvironmentValueEx(var_indications, efi_guid, buf, len, attr)
    
    if status == 0xC0000034 then -- Variable Not Found
        buf[0] = 0 -- Default to 0
        attr[0] = bit.bor(C.EFI_VARIABLE_NON_VOLATILE, C.EFI_VARIABLE_BOOTSERVICE_ACCESS, C.EFI_VARIABLE_RUNTIME_ACCESS) -- 0x7
    elseif status < 0 then
        return false, string.format("Query OsIndications failed: 0x%X", status)
    end
    
    -- 4. Set Bit 0
    -- buf[0] = buf[0] | 1
    -- LuaJIT's bit library operates on 32-bit. We must use FFI bitwise or manual.
    -- Since we just need to set the lowest bit:
    if bit.band(tonumber(buf[0]), 1) == 0 then
        buf[0] = buf[0] + 1
    end
    
    -- 5. Write back
    status = ntdll.NtSetSystemEnvironmentValueEx(var_indications, efi_guid, buf, 8, attr[0])
    
    if status < 0 then
        return false, string.format("Set OsIndications failed: 0x%X", status)
    end
    
    return true
end

return M