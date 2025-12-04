local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

-- 检测启动模式
-- 返回: "UEFI" 或 "BIOS"
function M.get_firmware_type()
    -- 尝试调用 GetFirmwareEnvironmentVariableW
    -- 只要 API 存在且不返回 ERROR_INVALID_FUNCTION (1)，即为 UEFI 环境
    -- 即使返回 ERROR_PRIVILEGE_NOT_HELD (1314)，也说明系统支持 UEFI 变量
    
    local dummy_guid = "{00000000-0000-0000-0000-000000000000}"
    local dummy_name = util.to_wide("NonExistentVar")
    
    kernel32.SetLastError(0)
    
    -- 尝试读取一个不存在的变量
    kernel32.GetFirmwareEnvironmentVariableW(dummy_name, util.to_wide(dummy_guid), nil, 0)
    local err = kernel32.GetLastError()
    
    if err == 1 then -- ERROR_INVALID_FUNCTION
        return "BIOS"
    else
        return "UEFI"
    end
end

-- 检测是否在 WinPE 环境下
-- WinPE 在 HKLM\System\CurrentControlSet\Control\MiniNT 键值存在
function M.is_winpe()
    local key = reg.open_key("HKLM", "System\\CurrentControlSet\\Control\\MiniNT")
    if key then
        key:close()
        return true
    end
    return false
end

return M