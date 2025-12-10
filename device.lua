local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local cfgmgr32 = require 'ffi.req' 'Windows.sdk.cfgmgr32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local C = ffi.C

local M = {}
local GUID_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})
local GUID_CDROM = ffi.new("GUID", {0x53f56308, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})
local GUID_USB_HUB = ffi.new("GUID", {0xf18a0e88, 0xc30c, 0x11d0, {0x88, 0x15, 0x00, 0xa0, 0xc9, 0x06, 0xbe, 0xd8}})

-- 内部辅助：通过 SetupAPI 查找指定 PhysicalDrive 的 DevInst
local function get_disk_devinst(drive_index)
    local flags = bit.bor(0x02, 0x10) -- PRESENT | DEVICEINTERFACE
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, flags)
    if hInfo == ffi.cast("HANDLE", -1) then return nil end
    
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA"); ifaceData.cbSize = ffi.sizeof(ifaceData)
    local i = 0
    local result = nil
    local req = ffi.new("DWORD[1]")
    local buf, detail, hDev, num
    
    ::loop::
    if setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) == 0 then goto done end
    if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_DISK, 0, ifaceData) == 0 then i = i + 1; goto loop end
    
    setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
    if req[0] == 0 then i = i + 1; goto loop end
    
    buf = ffi.new("uint8_t[?]", req[0])
    detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
    detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
    
    if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, detail, req[0], nil, nil) ~= 0 then
        hDev = kernel32.CreateFileW(detail.DevicePath, 0, 3, nil, 3, 0, nil)
        if hDev ~= ffi.cast("HANDLE", -1) then
            num = util.ioctl(hDev, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
            if num and tonumber(num.DeviceNumber) == drive_index then
                result = devData.DevInst
                kernel32.CloseHandle(hDev)
                goto done 
            end
            kernel32.CloseHandle(hDev)
        end
    end
    i = i + 1; goto loop
    
    ::done::
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return result
end

-- 内部辅助：获取逻辑盘符 (例如 "F:") 对应的物理设备号
-- 返回: DeviceNumber (number) 或 "EJECTED" (如果已直接弹出), DeviceType (number)
local function get_device_number_from_path(path)
    -- 规范化路径 "C:", "C:\" -> "\\.\C:"
    local vol_path = path
    if vol_path:match("^[A-Za-z]:$") then vol_path = "\\\\.\\" .. vol_path end
    if vol_path:match("^[A-Za-z]:\\$") then vol_path = "\\\\.\\" .. vol_path:sub(1,2) end
    
    local h = kernel32.CreateFileW(util.to_wide(vol_path), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return nil end
    
    local num = util.ioctl(h, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
    
    -- 如果获取不到 DeviceNumber，可能是光驱，尝试直接 IOCTL 弹出
    if not num then
        -- IOCTL_STORAGE_EJECT_MEDIA (0x2D4808)
        local eject_ok = util.ioctl(h, 0x2D4808)
        kernel32.CloseHandle(h)
        if eject_ok then return "EJECTED", nil end
        return nil, nil
    end
    
    kernel32.CloseHandle(h)
    return tonumber(num.DeviceNumber), tonumber(num.DeviceType)
end

-- [API] 复位端口 (Cycle USB Port)
function M.reset_port(physical_drive_index)
    local dev_inst = get_disk_devinst(physical_drive_index)
    if not dev_inst then return false, "Device not found" end
    
    local current = dev_inst
    local parent = ffi.new("DWORD[1]")
    local port = 0
    local hub_inst = 0
    local buf = ffi.new("wchar_t[1024]")
    local len = ffi.new("ULONG[1]")
    local type_ptr = ffi.new("ULONG[1]")
    local addr = ffi.new("DWORD[1]")
    
    -- 向上查找直到找到 USB HUB
    ::walk_up::
    len[0] = 2048
    if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current, 0x05, type_ptr, buf, len, 0) == 0 then
        local svc = util.from_wide(buf)
        if svc and svc:upper():find("USBHUB") then hub_inst = current; goto found_hub end
    end
    len[0] = 4
    if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current, 0x1C, type_ptr, addr, len, 0) == 0 then port = addr[0] end
    if cfgmgr32.CM_Get_Parent(parent, current, 0) == 0 then current = parent[0]; goto walk_up end
    return false, "USB Hub root reached without finding hub"

    ::found_hub::
    if hub_inst == 0 or port == 0 then return false, "USB Hub/Port invalid" end
    
    -- 查找 Hub 的设备路径
    local hub_path = nil
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_USB_HUB, nil, nil, bit.bor(0x02, 0x10))
    if hInfo ~= ffi.cast("HANDLE", -1) then
        local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
        local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA"); ifaceData.cbSize = ffi.sizeof(ifaceData)
        local i = 0
        local req = ffi.new("DWORD[1]")
        while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
            if devData.DevInst == hub_inst then
                if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_USB_HUB, 0, ifaceData) ~= 0 then
                    setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
                    if req[0] > 0 then
                        local b = ffi.new("uint8_t[?]", req[0])
                        local d = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", b)
                        d.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                        if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, d, req[0], nil, nil) ~= 0 then
                            hub_path = util.from_wide(d.DevicePath)
                        end
                    end
                end
                break
            end
            i = i + 1
        end
        setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    end
    if not hub_path then return false, "Hub path not found" end
    
    local hHub = kernel32.CreateFileW(util.to_wide(hub_path), C.GENERIC_WRITE, C.FILE_SHARE_WRITE, nil, C.OPEN_EXISTING, 0, nil)
    if hHub == ffi.cast("HANDLE", -1) then return false, util.last_error("Open Hub failed") end
    
    local params = ffi.new("USB_CYCLE_PORT_PARAMS")
    params.ConnectionIndex = port
    local res, err = util.ioctl(hHub, defs.IOCTL.USB_HUB_CYCLE_PORT, params, ffi.sizeof(params), params, ffi.sizeof(params))
    kernel32.CloseHandle(hHub)
    
    if not res then return false, err end
    return true
end

-- [API] 软复位驱动状态 (Disable -> Enable)
function M.reset_driver_state(physical_drive_index)
    local flags = bit.bor(0x02, 0x10) 
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, flags)
    if hInfo == ffi.cast("HANDLE", -1) then return false, "SetupDiGetClassDevs failed" end
    
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA"); ifaceData.cbSize = ffi.sizeof(ifaceData)
    local i = 0
    local target_dev = nil
    local req = ffi.new("DWORD[1]")
    local buf, detail, hDev, num
    
    ::loop::
    if setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) == 0 then goto done end
    if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_DISK, 0, ifaceData) == 0 then i = i + 1; goto loop end
    
    setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
    if req[0] == 0 then i = i + 1; goto loop end
    
    buf = ffi.new("uint8_t[?]", req[0])
    detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
    detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
    
    if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, detail, req[0], nil, nil) ~= 0 then
        hDev = kernel32.CreateFileW(detail.DevicePath, 0, 3, nil, 3, 0, nil)
        if hDev ~= ffi.cast("HANDLE", -1) then
            num = util.ioctl(hDev, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
            if num and tonumber(num.DeviceNumber) == physical_drive_index then
                target_dev = ffi.new("SP_DEVINFO_DATA")
                ffi.copy(target_dev, devData, ffi.sizeof(devData))
                kernel32.CloseHandle(hDev); goto done
            end
            kernel32.CloseHandle(hDev)
        end
    end
    i = i + 1; goto loop
    
    ::done::
    if not target_dev then
        setupapi.SetupDiDestroyDeviceInfoList(hInfo)
        return false, "Device not found"
    end
    
    local params = ffi.new("SP_PROPCHANGE_PARAMS")
    params.ClassInstallHeader.cbSize = ffi.sizeof("SP_CLASSINSTALL_HEADER")
    params.ClassInstallHeader.InstallFunction = 0x12 -- DIF_PROPERTYCHANGE
    params.Scope = 0x2 -- DICS_FLAG_CONFIGSPECIFIC
    
    params.StateChange = 0x2 -- DICS_DISABLE
    setupapi.SetupDiSetClassInstallParamsW(hInfo, target_dev, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params))
    setupapi.SetupDiChangeState(hInfo, target_dev)
    
    kernel32.Sleep(250)
    
    params.StateChange = 0x1 -- DICS_ENABLE
    setupapi.SetupDiSetClassInstallParamsW(hInfo, target_dev, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params))
    local res = setupapi.SetupDiChangeState(hInfo, target_dev)
    
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    
    if res == 0 then return false, util.last_error("ChangeState failed") end
    return true
end

-- [API] 组合复位尝试
function M.reset(physical_drive_index, wait_ms)
    local ok_port, err_port = M.reset_port(physical_drive_index)
    if ok_port then 
        kernel32.Sleep(wait_ms or 2000) 
        return true, "Hardware Port Cycle" 
    end
    local ok_disk, err_disk = M.reset_driver_state(physical_drive_index)
    if ok_disk then 
        return true, "Software PnP Cycle" 
    end
    return false, "Reset failed"
end

-- [API] 弹出/移除设备
-- @param drive: 盘符 (如 "F:")
function M.eject(drive)
    local dev_num, dev_type = get_device_number_from_path(drive)
    if dev_num == "EJECTED" then return true, "Media Ejected" end
    if not dev_num then return false, "Device not found or access denied" end
    
    -- 确定设备接口 GUID (2 = FILE_DEVICE_CD_ROM)
    local guid = (dev_type == 2) and GUID_CDROM or GUID_DISK 
    
    -- 遍历设备树寻找对应的 DevInst
    local hInfo = setupapi.SetupDiGetClassDevsW(guid, nil, nil, bit.bor(0x02, 0x10)) -- PRESENT | DEVICEINTERFACE
    if hInfo == ffi.cast("HANDLE", -1) then return false, "SetupDiGetClassDevs failed" end
    
    local iface = ffi.new("SP_DEVICE_INTERFACE_DATA"); iface.cbSize = ffi.sizeof(iface)
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local i = 0
    local target_inst = 0
    local req = ffi.new("DWORD[1]")
    
    while setupapi.SetupDiEnumDeviceInterfaces(hInfo, nil, guid, i, iface) ~= 0 do
        setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, nil, 0, req, nil)
        if req[0] > 0 then
            local buf = ffi.new("uint8_t[?]", req[0])
            local detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
            detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
            
            if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, detail, req[0], nil, devData) ~= 0 then
                -- 打开设备路径比对 DeviceNumber
                local hDev = kernel32.CreateFileW(detail.DevicePath, 0, 3, nil, 3, 0, nil)
                if hDev ~= ffi.cast("HANDLE", -1) then
                    local num = util.ioctl(hDev, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
                    kernel32.CloseHandle(hDev)
                    if num and tonumber(num.DeviceNumber) == dev_num then
                        target_inst = devData.DevInst
                        break
                    end
                end
            end
        end
        i = i + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    
    if target_inst == 0 then return false, "Device DevNode not found" end
    
    -- 向上回溯寻找可移除的父节点 (Removable Parent)
    -- U盘通常作为磁盘是不可移除的，但其父节点(USB Mass Storage)是可移除的
    local current = target_inst
    local parent = ffi.new("DWORD[1]")
    local status = ffi.new("ULONG[1]")
    local problem = ffi.new("ULONG[1]")
    
    -- 尝试最多回溯 3 层
    for j=1, 3 do
        if cfgmgr32.CM_Get_DevNode_Status(status, problem, current, 0) == 0 then
            -- DN_REMOVABLE (0x00004000) or DN_DISABLEABLE (0x00002000)
            if bit.band(status[0], 0x4000) ~= 0 then
                break -- 找到可移除节点
            end
        end
        if cfgmgr32.CM_Get_Parent(parent, current, 0) ~= 0 then break end
        current = parent[0]
    end
    
    -- 执行弹出
    local veto_type = ffi.new("PNP_VETO_TYPE[1]")
    local veto_name = ffi.new("wchar_t[260]")
    
    local res = cfgmgr32.CM_Request_Device_EjectW(current, veto_type, veto_name, 260, 0)
    
    if res == 0 then return true, "Success" end
    
    -- 如果失败，返回拒接原因 (CR_REMOVE_VETOED = 0x17)
    return false, string.format("Eject failed: CR=0x%X, Veto=%d", res, tonumber(veto_type[0]))
end

return M