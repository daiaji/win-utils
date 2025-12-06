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

return M