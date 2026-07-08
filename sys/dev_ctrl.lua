local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local cfgmgr32 = require 'ffi.req' 'Windows.sdk.cfgmgr32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- SetupAPI Function Codes
local DIF_PROPERTYCHANGE = 0x12
local DIF_REMOVE         = 0x05

-- Scopes / States
local DICS_FLAG_GLOBAL   = 0x01
local DICS_FLAG_CONFIGSPECIFIC = 0x02
local DICS_ENABLE        = 0x01
local DICS_DISABLE       = 0x02
local DICS_PROPCHANGE    = 0x03 -- Stop and Restart
local DI_REMOVEDEVICE_GLOBAL = 0x01

local DIGCF_ALLCLASSES   = 0x04
local DIGCF_PRESENT      = 0x02

-- [Internal] 核心状态变更逻辑
-- @param hwid_pattern: 硬件 ID 匹配串
-- @param action_type: "prop_change" | "remove"
-- @param param_code: DICS_xxx (for prop_change) or DI_xxx (for remove)
local function apply_action(hwid_pattern, action_type, param_code)
    local flags = bit.bor(DIGCF_ALLCLASSES, DIGCF_PRESENT)
    local hInfo = setupapi.SetupDiGetClassDevsW(nil, nil, nil, flags)
    if hInfo == ffi.cast("HANDLE", -1) then 
        return false, util.last_error("SetupDiGetClassDevs failed") 
    end
    
    local devData = ffi.new("SP_DEVINFO_DATA")
    devData.cbSize = ffi.sizeof(devData)
    
    local i = 0
    local count = 0
    local buf = ffi.new("wchar_t[1024]")
    
    -- 1. 遍历设备
    while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
        local match = false
        
        -- 2. 匹配 Hardware IDs
        if setupapi.SetupDiGetDeviceRegistryPropertyW(hInfo, devData, 1, nil, ffi.cast("BYTE*", buf), 2048, nil) ~= 0 then
            local ptr = buf
            while true do
                local id = util.from_wide(ptr)
                if not id or id == "" then break end
                
                if id:upper():find(hwid_pattern:upper(), 1, true) then
                    match = true
                    break
                end
                
                local len = 0; while ptr[len] ~= 0 do len = len + 1 end
                ptr = ptr + len + 1
                if ptr[0] == 0 then break end
            end
        end
        
        if match then
            -- 3. 执行动作
            local res = 0
            
            if action_type == "prop_change" then
                local params = ffi.new("SP_PROPCHANGE_PARAMS")
                params.ClassInstallHeader.cbSize = ffi.sizeof("SP_CLASSINSTALL_HEADER")
                params.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE
                params.Scope = DICS_FLAG_GLOBAL
                params.StateChange = param_code
                
                if setupapi.SetupDiSetClassInstallParamsW(hInfo, devData, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params)) ~= 0 then
                    if setupapi.SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, hInfo, devData) ~= 0 then
                        res = 1
                    end
                end
                
            elseif action_type == "remove" then
                local params = ffi.new("SP_REMOVEDEVICE_PARAMS")
                params.ClassInstallHeader.cbSize = ffi.sizeof("SP_CLASSINSTALL_HEADER")
                params.ClassInstallHeader.InstallFunction = DIF_REMOVE
                params.Scope = DI_REMOVEDEVICE_GLOBAL
                
                if setupapi.SetupDiSetClassInstallParamsW(hInfo, devData, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params)) ~= 0 then
                    if setupapi.SetupDiCallClassInstaller(DIF_REMOVE, hInfo, devData) ~= 0 then
                        res = 1
                    end
                end
            end
            
            if res ~= 0 then count = count + 1 end
        end
        
        i = i + 1
    end
    
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    
    if count > 0 then return true, count else return false, "No devices matched or action failed" end
end

-- [API] 启用设备 (DEVI *enable)
function M.enable(hwid)
    return apply_action(hwid, "prop_change", DICS_ENABLE)
end

-- [API] 禁用设备 (DEVI *disable)
function M.disable(hwid)
    return apply_action(hwid, "prop_change", DICS_DISABLE)
end

-- [API] 重启设备 (DEVI *restart)
function M.restart(hwid)
    return apply_action(hwid, "prop_change", DICS_PROPCHANGE)
end

-- [API] 移除设备实例 (DEVI *remove)
-- 注意：这不会删除驱动文件，只是从设备管理器中移除设备节点。
-- 刷新后 Windows 会尝试重新安装。
function M.remove(hwid)
    return apply_action(hwid, "remove", 0)
end

-- [API] 扫描硬件改动 (DEVI *rescan)
-- 触发 PnP 管理器重新枚举设备树
function M.rescan()
    local root_inst = ffi.new("DWORD[1]")
    
    -- 获取设备树根节点 (ROOT)
    if cfgmgr32.CM_Locate_DevNodeW(root_inst, nil, 0) ~= 0 then
        return false, "Locate Root DevNode failed"
    end
    
    -- 重新枚举根节点 (CM_Reenumerate_DevNode)
    -- 0 = CM_REENUMERATE_NORMAL
    if cfgmgr32.CM_Reenumerate_DevNode(root_inst[0], 0) ~= 0 then
        return false, "Reenumerate failed"
    end
    
    return true
end

return M
