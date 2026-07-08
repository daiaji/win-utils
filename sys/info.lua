local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

function M.get_firmware_type()
    local dummy_name = util.to_wide("NonExistentVar")
    local dummy_guid = util.to_wide("{00000000-0000-0000-0000-000000000000}")
    
    kernel32.SetLastError(0)
    kernel32.GetFirmwareEnvironmentVariableW(dummy_name, dummy_guid, nil, 0)
    local err = kernel32.GetLastError()
    
    -- ERROR_INVALID_FUNCTION (1) = BIOS
    if err == 1 then return "BIOS" else return "UEFI" end
end

function M.is_winpe()
    local k = reg.open_key("HKLM", "System\\CurrentControlSet\\Control\\MiniNT")
    if k then k:close(); return true end
    return false
end

-- [API] 获取系统内存状态
-- @return: table { total_mb, avail_mb, load_percent }
function M.get_memory_info()
    local ms = ffi.new("MEMORYSTATUSEX")
    ms.dwLength = ffi.sizeof(ms)
    
    if kernel32.GlobalMemoryStatusEx(ms) == 0 then 
        return nil, util.last_error("GlobalMemoryStatusEx failed")
    end
    
    return {
        total_mb = tonumber(ms.ullTotalPhys / 1048576),
        avail_mb = tonumber(ms.ullAvailPhys / 1048576),
        load = tonumber(ms.dwMemoryLoad)
    }
end

function M.get_power_status()
    local status = ffi.new("SYSTEM_POWER_STATUS")

    if kernel32.GetSystemPowerStatus(status) == 0 then
        return nil, util.last_error("GetSystemPowerStatus failed")
    end

    return {
        ac_line_status = tonumber(status.ACLineStatus),
        battery_flag = tonumber(status.BatteryFlag),
        battery_life_percent = tonumber(status.BatteryLifePercent),
        system_status_flag = tonumber(status.SystemStatusFlag),
        battery_life_time = tonumber(status.BatteryLifeTime),
        battery_full_life_time = tonumber(status.BatteryFullLifeTime),
    }
end

function M.is_laptop()
    local status = M.get_power_status()
    if not status then return false end

    -- BatteryFlag 0x80 means no system battery; 0xFF means unknown status.
    return status.battery_flag ~= 0x80 and status.battery_flag ~= 0xFF
end

function M.get_arch()
    return ffi.arch
end

return M
