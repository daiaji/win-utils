local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local cfgmgr32 = require 'ffi.req' 'Windows.sdk.cfgmgr32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local defs = require 'win-utils.disk.defs'

local M = {}
local C = ffi.C
local GUID_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})
local GUID_USB_HUB = ffi.new("GUID", {0xf18a0e88, 0xc30c, 0x11d0, {0x88, 0x15, 0x00, 0xa0, 0xc9, 0x06, 0xbe, 0xd8}})

-- 辅助：获取设备的 DevInst
local function get_disk_devinst(drive_index)
    local flags = bit.bor(0x02, 0x10) -- PRESENT | DEVICEINTERFACE
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, flags)
    if hInfo == ffi.cast("HANDLE", -1) then return nil end
    
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA"); ifaceData.cbSize = ffi.sizeof(ifaceData)
    local i = 0
    local result = nil
    
    while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
        if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_DISK, 0, ifaceData) ~= 0 then
            local req = ffi.new("DWORD[1]")
            setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
            if req[0] > 0 then
                local buf = ffi.new("uint8_t[?]", req[0])
                local detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
                detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, detail, req[0], nil, nil) ~= 0 then
                    local hDev = kernel32.CreateFileW(detail.DevicePath, 0, 3, nil, 3, 0, nil)
                    if hDev ~= ffi.cast("HANDLE", -1) then
                        local num = ffi.new("STORAGE_DEVICE_NUMBER")
                        local bytes = ffi.new("DWORD[1]")
                        if kernel32.DeviceIoControl(hDev, defs.IOCTL.STORAGE_GET_DEVICE_NUMBER, nil, 0, num, ffi.sizeof(num), bytes, nil) ~= 0 then
                            if tonumber(num.DeviceNumber) == drive_index then
                                result = devData.DevInst
                            end
                        end
                        kernel32.CloseHandle(hDev)
                    end
                end
            end
        end
        if result then break end
        i = i + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return result
end

-- 辅助：获取 Hub 路径
local function get_hub_path(hub_inst)
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_USB_HUB, nil, nil, bit.bor(0x02, 0x10))
    if hInfo == ffi.cast("HANDLE", -1) then return nil end
    
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA"); ifaceData.cbSize = ffi.sizeof(ifaceData)
    local i = 0
    local path = nil
    
    while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
        if devData.DevInst == hub_inst then
            if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_USB_HUB, 0, ifaceData) ~= 0 then
                local req = ffi.new("DWORD[1]")
                setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
                if req[0] > 0 then
                    local buf = ffi.new("uint8_t[?]", req[0])
                    local detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
                    detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                    if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, detail, req[0], nil, nil) ~= 0 then
                        path = util.from_wide(detail.DevicePath)
                    end
                end
            end
            break
        end
        i = i + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return path
end

function M.cycle_port(physical_drive_index)
    local dev_inst = get_disk_devinst(physical_drive_index)
    if not dev_inst then return false, "Device not found" end
    
    local current = dev_inst
    local parent = ffi.new("DWORD[1]")
    local port = 0
    local hub_inst = 0
    
    -- 向上遍历直到找到 USBHUB
    while true do
        local buf = ffi.new("wchar_t[1024]")
        local len = ffi.new("ULONG[1]", 2048)
        local type_ptr = ffi.new("ULONG[1]")
        
        -- 获取 Service 属性
        if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current, 0x05, type_ptr, buf, len, 0) == 0 then -- CM_DRP_SERVICE
            local svc = util.from_wide(buf)
            if svc and svc:upper():find("USBHUB") then
                hub_inst = current
                break
            end
        end
        
        -- 获取 Address (Port Number)
        local addr = ffi.new("DWORD[1]")
        len[0] = 4
        if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current, 0x1C, type_ptr, addr, len, 0) == 0 then -- CM_DRP_ADDRESS
            port = addr[0]
        end
        
        if cfgmgr32.CM_Get_Parent(parent, current, 0) ~= 0 then break end
        current = parent[0]
    end
    
    if hub_inst == 0 or port == 0 then return false, "USB Hub/Port not found" end
    
    local hub_path = get_hub_path(hub_inst)
    if not hub_path then return false, "Hub path not found" end
    
    local hHub = kernel32.CreateFileW(util.to_wide(hub_path), C.GENERIC_WRITE, C.FILE_SHARE_WRITE, nil, C.OPEN_EXISTING, 0, nil)
    if hHub == ffi.cast("HANDLE", -1) then return false, "Open Hub failed" end
    
    local params = ffi.new("USB_CYCLE_PORT_PARAMS")
    params.ConnectionIndex = port
    
    local res = util.ioctl(hHub, defs.IOCTL.USB_HUB_CYCLE_PORT, params, ffi.sizeof(params), params, ffi.sizeof(params))
    kernel32.CloseHandle(hHub)
    
    return res ~= nil
end

function M.cycle_disk(physical_drive_index)
    local flags = bit.bor(0x02, 0x10) 
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, flags)
    if hInfo == ffi.cast("HANDLE", -1) then return false, "SetupDiGetClassDevs failed" end
    
    local devData = ffi.new("SP_DEVINFO_DATA")
    devData.cbSize = ffi.sizeof(devData)
    local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA")
    ifaceData.cbSize = ffi.sizeof(ifaceData)
    local i = 0
    local target_dev = nil
    
    while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
        if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_DISK, 0, ifaceData) ~= 0 then
            local req = ffi.new("DWORD[1]")
            setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, nil, 0, req, nil)
            if req[0] > 0 then
                local buf = ffi.new("uint8_t[?]", req[0])
                local detail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
                detail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, ifaceData, detail, req[0], nil, nil) ~= 0 then
                    local hDev = kernel32.CreateFileW(detail.DevicePath, 0, 3, nil, 3, 0, nil)
                    if hDev ~= ffi.cast("HANDLE", -1) then
                        local num = ffi.new("STORAGE_DEVICE_NUMBER")
                        local bytes = ffi.new("DWORD[1]")
                        if kernel32.DeviceIoControl(hDev, defs.IOCTL.STORAGE_GET_DEVICE_NUMBER, nil, 0, num, ffi.sizeof(num), bytes, nil) ~= 0 then
                            if tonumber(num.DeviceNumber) == physical_drive_index then
                                target_dev = ffi.new("SP_DEVINFO_DATA")
                                ffi.copy(target_dev, devData, ffi.sizeof(devData))
                            end
                        end
                        kernel32.CloseHandle(hDev)
                    end
                end
            end
        end
        if target_dev then break end
        i = i + 1
    end
    
    if not target_dev then
        setupapi.SetupDiDestroyDeviceInfoList(hInfo)
        return false, "Device not found"
    end
    
    local params = ffi.new("SP_PROPCHANGE_PARAMS")
    params.ClassInstallHeader.cbSize = ffi.sizeof("SP_CLASSINSTALL_HEADER")
    params.ClassInstallHeader.InstallFunction = 0x12 
    params.Scope = 0x2 
    params.HwProfile = 0
    
    params.StateChange = 0x2 -- DICS_DISABLE
    setupapi.SetupDiSetClassInstallParamsW(hInfo, target_dev, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params))
    setupapi.SetupDiChangeState(hInfo, target_dev)
    
    kernel32.Sleep(250)
    
    params.StateChange = 0x1 -- DICS_ENABLE
    setupapi.SetupDiSetClassInstallParamsW(hInfo, target_dev, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params))
    local res = setupapi.SetupDiChangeState(hInfo, target_dev)
    
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return res ~= 0
end

return M