local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

-- [Modern LuaJIT] 检测固件类型 (UEFI / BIOS)
function M.get_firmware_type()
    -- 利用 GetFirmwareEnvironmentVariableW 的错误码特性
    -- 这是一个比 GetFirmwareType API 更兼容老系统的方法
    local dummy_name = util.to_wide("NonExistentVar")
    local dummy_guid = util.to_wide("{00000000-0000-0000-0000-000000000000}")
    
    kernel32.SetLastError(0)
    kernel32.GetFirmwareEnvironmentVariableW(dummy_name, dummy_guid, nil, 0)
    local err = kernel32.GetLastError()
    
    -- ERROR_INVALID_FUNCTION (1) = Legacy BIOS
    -- ERROR_VARIABLE_NOT_FOUND (203) = UEFI (支持变量但找不到)
    -- ERROR_PRIVILEGE_NOT_HELD (1314) = UEFI (支持但没权限)
    if err == 1 then 
        return "BIOS"
    else
        return "UEFI"
    end
end

-- 检测是否为 WinPE (预安装环境)
function M.is_winpe()
    -- WinPE 特征键值: HKLM\System\CurrentControlSet\Control\MiniNT
    local k = reg.open_key("HKLM", "System\\CurrentControlSet\\Control\\MiniNT")
    if k then
        k:close()
        return true
    end
    return false
end

return M