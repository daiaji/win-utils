local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local cfgmgr32 = require 'ffi.req' 'Windows.sdk.cfgmgr32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local table_new = require 'table.new'

local M = {}

-- SetupAPI 设备属性常量
local SPDRP_DEVICEDESC    = 0x00000000
local SPDRP_HARDWAREID    = 0x00000001
local SPDRP_COMPATIBLEIDS = 0x00000002
local SPDRP_CLASS         = 0x00000007
local SPDRP_CLASSGUID     = 0x00000008
local SPDRP_FRIENDLYNAME  = 0x0000000C

-- Configuration Manager 状态常量
local DN_HAS_PROBLEM = 0x00000400
local DN_STARTED     = 0x00000008
local DN_DISABLEABLE = 0x00002000

-- [Internal] 获取设备的注册表属性 (兼容 REG_SZ 和 REG_MULTI_SZ)
local function get_dev_prop(hDevInfo, devData, prop_id)
    local req_sz = ffi.new("DWORD[1]")
    local type_ptr = ffi.new("DWORD[1]")
    
    -- 第一次调用获取所需缓冲区大小
    setupapi.SetupDiGetDeviceRegistryPropertyW(hDevInfo, devData, prop_id, type_ptr, nil, 0, req_sz)
    
    local err = kernel32.GetLastError()
    if err ~= 122 then return nil end -- 122 = ERROR_INSUFFICIENT_BUFFER
    
    local buf = ffi.new("uint8_t[?]", req_sz[0])
    if setupapi.SetupDiGetDeviceRegistryPropertyW(hDevInfo, devData, prop_id, type_ptr, buf, req_sz[0], nil) == 0 then
        return nil
    end
    
    -- REG_SZ (1)
    if type_ptr[0] == 1 then
        return util.from_wide(ffi.cast("wchar_t*", buf))
    end
    
    -- REG_MULTI_SZ (7)
    if type_ptr[0] == 7 then
        local res = {}
        local ptr = ffi.cast("wchar_t*", buf)
        local offset = 0
        local limit = req_sz[0] / 2 -- 宽字符数量
        
        while offset < limit do
            local str = util.from_wide(ptr + offset)
            if not str or str == "" then break end
            table.insert(res, str)
            offset = offset + #str + 1 -- 跳过字符串本身和结尾的 \0
        end
        return res
    end
    
    return nil
end

-- [API] 枚举系统中的设备
-- @param opts: 过滤选项表
--    opts.present (boolean): 仅列出当前存在的设备 (默认 true)
--    opts.problem (boolean): 仅列出有问题的设备 (默认 false)
--    opts.detail  (boolean): 是否获取详细信息如 HWID (默认 true)
-- @return: list table
function M.enum_devices(opts)
    opts = opts or {}
    local flags = 0
    
    -- DIGCF_PRESENT (0x02): 仅返回当前存在的设备
    if opts.present ~= false then 
        flags = bit.bor(flags, 0x02) 
    end 
    
    -- DIGCF_ALLCLASSES (0x04): 返回所有已安装类的设备列表
    flags = bit.bor(flags, 0x04) 
    -- DIGCF_DEVICEINTERFACE (0x10): 如果需要接口 (这里我们主要关注硬件ID，通常不需要接口)
    -- flags = bit.bor(flags, 0x10)

    local hDevInfo = setupapi.SetupDiGetClassDevsW(nil, nil, nil, flags)
    if hDevInfo == ffi.cast("HANDLE", -1) then 
        return nil, util.last_error("SetupDiGetClassDevs failed") 
    end

    local devData = ffi.new("SP_DEVINFO_DATA")
    devData.cbSize = ffi.sizeof(devData)
    
    local list = {}
    local i = 0
    
    local status = ffi.new("ULONG[1]")
    local problem = ffi.new("ULONG[1]")
    
    while setupapi.SetupDiEnumDeviceInfo(hDevInfo, i, devData) ~= 0 do
        local keep = true
        local prob_code = 0
        local is_problem = false
        
        -- 获取设备节点状态
        if cfgmgr32.CM_Get_DevNode_Status(status, problem, devData.DevInst, 0) == 0 then
            prob_code = problem[0]
            -- 如果状态位包含 DN_HAS_PROBLEM 或 problem code != 0，视为有问题
            if bit.band(status[0], DN_HAS_PROBLEM) ~= 0 or prob_code ~= 0 then
                is_problem = true
            end
        end
        
        -- 根据选项过滤
        if opts.problem and not is_problem then 
            keep = false 
        end
        
        if keep then
            local info = {
                index = i,
                inst = devData.DevInst,
                problem = prob_code,
                has_problem = is_problem
            }
            
            if opts.detail ~= false then
                -- 优先获取设备描述，如果没有则获取友好名称
                info.desc = get_dev_prop(hDevInfo, devData, SPDRP_DEVICEDESC) or get_dev_prop(hDevInfo, devData, SPDRP_FRIENDLYNAME)
                info.class = get_dev_prop(hDevInfo, devData, SPDRP_CLASS)
                
                -- 获取硬件ID列表
                info.hwids = get_dev_prop(hDevInfo, devData, SPDRP_HARDWAREID) or {}
                
                -- 获取兼容ID列表
                info.compat_ids = get_dev_prop(hDevInfo, devData, SPDRP_COMPATIBLEIDS) or {}
                
                info.guid = util.guid_to_str(devData.ClassGuid)
            end
            
            table.insert(list, info)
        end
        i = i + 1
    end
    
    setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
    return list
end

-- [API] 获取所有缺失驱动的设备的硬件ID列表 (Set 结构)
-- 返回格式: { ["PCI\\VEN_xxxx..."] = true, ... }
function M.get_missing_driver_ids()
    local devs = M.enum_devices({ problem = true, present = true })
    local id_set = {}
    if not devs then return id_set end
    
    for _, dev in ipairs(devs) do
        -- 收集 Hardware IDs
        if dev.hwids then
            for _, id in ipairs(dev.hwids) do 
                id_set[id:upper()] = true 
            end
        end
        -- 收集 Compatible IDs (INF 有时只匹配 Compatible ID)
        if dev.compat_ids then
            for _, id in ipairs(dev.compat_ids) do 
                id_set[id:upper()] = true 
            end
        end
    end
    return id_set
end

return M