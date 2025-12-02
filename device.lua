local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local cfgmgr32 = require 'ffi.req' 'Windows.sdk.cfgmgr32'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

local GUID_DEVINTERFACE_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})

function M.cycle_disk(physical_drive_index)
    -- DIGCF_DEVICEINTERFACE (0x10) | DIGCF_PRESENT (0x02)
    local flags = bit.bor(0x02, 0x10) 
    local hDevInfo = setupapi.SetupDiGetClassDevsW(GUID_DEVINTERFACE_DISK, nil, nil, flags)
    
    if hDevInfo == ffi.cast("void*", -1) then return false, "SetupDiGetClassDevs failed" end
    
    local devInfoData = ffi.new("SP_DEVINFO_DATA")
    devInfoData.cbSize = ffi.sizeof(devInfoData)
    local idx = 0
    local found_devInfoData = nil
    
    while setupapi.SetupDiEnumDeviceInfo(hDevInfo, idx, devInfoData) ~= 0 do
        local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA")
        ifaceData.cbSize = ffi.sizeof(ifaceData)
        
        if setupapi.SetupDiEnumDeviceInterfaces(hDevInfo, devInfoData, GUID_DEVINTERFACE_DISK, 0, ifaceData) ~= 0 then
            local reqSize = ffi.new("DWORD[1]")
            setupapi.SetupDiGetDeviceInterfaceDetailW(hDevInfo, ifaceData, nil, 0, reqSize, nil)
            
            if reqSize[0] > 0 then
                local detailBuf = ffi.new("uint8_t[?]", reqSize[0])
                local pDetail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", detailBuf)
                pDetail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                
                if setupapi.SetupDiGetDeviceInterfaceDetailW(hDevInfo, ifaceData, pDetail, reqSize[0], nil, nil) ~= 0 then
                    -- GENERIC_READ, FILE_SHARE_READ|WRITE, OPEN_EXISTING
                    local hDev = kernel32.CreateFileW(pDetail.DevicePath, 0, bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, C.OPEN_EXISTING, 0, nil)
                    if hDev ~= ffi.cast("HANDLE", -1) then
                        local num_buf = ffi.new("STORAGE_DEVICE_NUMBER")
                        local bytes = ffi.new("DWORD[1]")
                        if kernel32.DeviceIoControl(hDev, C.IOCTL_STORAGE_GET_DEVICE_NUMBER, nil, 0, num_buf, ffi.sizeof(num_buf), bytes, nil) ~= 0 then
                            if tonumber(num_buf.DeviceNumber) == physical_drive_index then
                                found_devInfoData = ffi.new("SP_DEVINFO_DATA")
                                ffi.copy(found_devInfoData, devInfoData, ffi.sizeof("SP_DEVINFO_DATA"))
                            end
                        end
                        kernel32.CloseHandle(hDev)
                    end
                end
            end
        end
        
        if found_devInfoData then break end
        idx = idx + 1
    end
    
    if not found_devInfoData then
        setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
        return false, "Device not found"
    end
    
    -- SetupAPI Soft Cycle
    local params = ffi.new("SP_PROPCHANGE_PARAMS")
    params.ClassInstallHeader.cbSize = ffi.sizeof("SP_CLASSINSTALL_HEADER")
    params.ClassInstallHeader.InstallFunction = setupapi.DIF_PROPERTYCHANGE
    params.Scope = setupapi.DICS_FLAG_CONFIGSPECIFIC
    params.HwProfile = 0
    
    params.StateChange = setupapi.DICS_DISABLE
    if setupapi.SetupDiSetClassInstallParamsW(hDevInfo, found_devInfoData, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params)) == 0 then
        setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
        return false, "SetClassInstallParams(Disable) failed"
    end
    
    setupapi.SetupDiChangeState(hDevInfo, found_devInfoData)
    
    kernel32.Sleep(250) 
    
    params.StateChange = setupapi.DICS_ENABLE
    setupapi.SetupDiSetClassInstallParamsW(hDevInfo, found_devInfoData, ffi.cast("PSP_CLASSINSTALL_HEADER", params), ffi.sizeof(params))
    
    local res = setupapi.SetupDiChangeState(hDevInfo, found_devInfoData)
    
    setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
    
    return res ~= 0
end

function M.cycle_port(physical_drive_index)
    local target_dev_inst = 0
    local port_number = 0
    local hub_path = nil
    
    -- 1. Locate Device Instance from Drive Index
    local flags = bit.bor(0x02, 0x10) 
    local hDevInfo = setupapi.SetupDiGetClassDevsW(GUID_DEVINTERFACE_DISK, nil, nil, flags)
    
    if hDevInfo == ffi.cast("void*", -1) then return false, "SetupDiGetClassDevs failed" end
    
    local devInfoData = ffi.new("SP_DEVINFO_DATA")
    devInfoData.cbSize = ffi.sizeof(devInfoData)
    local idx = 0
    local found = false
    
    while setupapi.SetupDiEnumDeviceInfo(hDevInfo, idx, devInfoData) ~= 0 do
        local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA")
        ifaceData.cbSize = ffi.sizeof(ifaceData)
        
        if setupapi.SetupDiEnumDeviceInterfaces(hDevInfo, devInfoData, GUID_DEVINTERFACE_DISK, 0, ifaceData) ~= 0 then
            local reqSize = ffi.new("DWORD[1]")
            setupapi.SetupDiGetDeviceInterfaceDetailW(hDevInfo, ifaceData, nil, 0, reqSize, nil)
            
            if reqSize[0] > 0 then
                local detailBuf = ffi.new("uint8_t[?]", reqSize[0])
                local pDetail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", detailBuf)
                pDetail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                
                if setupapi.SetupDiGetDeviceInterfaceDetailW(hDevInfo, ifaceData, pDetail, reqSize[0], nil, nil) ~= 0 then
                    local hDev = kernel32.CreateFileW(pDetail.DevicePath, 0, bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, C.OPEN_EXISTING, 0, nil)
                    if hDev ~= ffi.cast("HANDLE", -1) then
                        local num_buf = ffi.new("STORAGE_DEVICE_NUMBER")
                        local bytes = ffi.new("DWORD[1]")
                        if kernel32.DeviceIoControl(hDev, C.IOCTL_STORAGE_GET_DEVICE_NUMBER, nil, 0, num_buf, ffi.sizeof(num_buf), bytes, nil) ~= 0 then
                            if tonumber(num_buf.DeviceNumber) == physical_drive_index then
                                target_dev_inst = devInfoData.DevInst
                                found = true
                            end
                        end
                        kernel32.CloseHandle(hDev)
                    end
                end
            end
        end
        if found then break end
        idx = idx + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
    
    if not found then return false, "Device not found for cycle_port" end
    
    -- 2. Traverse up to find the Parent Hub and Port Number
    local current_inst = target_dev_inst
    local parent_inst = ffi.new("DEVINST[1]")
    local buf_size = 1024
    local buf = ffi.new("wchar_t[?]", buf_size)
    local len = ffi.new("ULONG[1]")
    local type_ptr = ffi.new("ULONG[1]")
    
    while true do
        len[0] = buf_size * 2
        if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current_inst, cfgmgr32.CM_DRP_SERVICE, type_ptr, buf, len, 0) == 0 then
            local service = util.from_wide(buf)
            if service and (service:upper():find("USBHUB")) then
                break
            end
        end
        
        len[0] = 4
        local addr_buf = ffi.new("DWORD[1]")
        if cfgmgr32.CM_Get_DevNode_Registry_PropertyW(current_inst, cfgmgr32.CM_DRP_ADDRESS, type_ptr, addr_buf, len, 0) == 0 then
             port_number = addr_buf[0]
        end

        if cfgmgr32.CM_Get_Parent(parent_inst, current_inst, 0) ~= 0 then
            return false, "Reached root without finding USB Hub"
        end
        current_inst = parent_inst[0]
    end
    
    -- 3. Resolve Hub Interface Path
    local GUID_DEVINTERFACE_USB_HUB = ffi.new("GUID", {0xf18a0e88, 0xc30c, 0x11d0, {0x88, 0x15, 0x00, 0xa0, 0xc9, 0x06, 0xbe, 0xd8}})
    local hHubInfo = setupapi.SetupDiGetClassDevsW(GUID_DEVINTERFACE_USB_HUB, nil, nil, bit.bor(0x02, 0x10))
    if hHubInfo == ffi.cast("void*", -1) then return false, "SetupDiGetClassDevs(HUB) failed" end
    
    local hubInfoData = ffi.new("SP_DEVINFO_DATA")
    hubInfoData.cbSize = ffi.sizeof(hubInfoData)
    idx = 0
    local hub_found = false
    
    while setupapi.SetupDiEnumDeviceInfo(hHubInfo, idx, hubInfoData) ~= 0 do
        if hubInfoData.DevInst == current_inst then
            local ifaceData = ffi.new("SP_DEVICE_INTERFACE_DATA")
            ifaceData.cbSize = ffi.sizeof(ifaceData)
            if setupapi.SetupDiEnumDeviceInterfaces(hHubInfo, hubInfoData, GUID_DEVINTERFACE_USB_HUB, 0, ifaceData) ~= 0 then
                 local reqSize = ffi.new("DWORD[1]")
                 setupapi.SetupDiGetDeviceInterfaceDetailW(hHubInfo, ifaceData, nil, 0, reqSize, nil)
                 if reqSize[0] > 0 then
                     local detailBuf = ffi.new("uint8_t[?]", reqSize[0])
                     local pDetail = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", detailBuf)
                     pDetail.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                     if setupapi.SetupDiGetDeviceInterfaceDetailW(hHubInfo, ifaceData, pDetail, reqSize[0], nil, nil) ~= 0 then
                         hub_path = util.from_wide(pDetail.DevicePath)
                         hub_found = true
                     end
                 end
            end
            break
        end
        idx = idx + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hHubInfo)
    
    if not hub_found or not hub_path then return false, "Could not resolve Hub Path" end
    if port_number == 0 then return false, "Could not determine Port Number" end
    
    -- 4. Send IOCTL
    local hHub = kernel32.CreateFileW(util.to_wide(hub_path), C.GENERIC_WRITE, C.FILE_SHARE_WRITE, nil, C.OPEN_EXISTING, 0, nil)
    if hHub == ffi.cast("HANDLE", -1) then return false, "Open Hub failed: " .. util.format_error() end
    
    local cycle_params = ffi.new("USB_CYCLE_PORT_PARAMS")
    cycle_params.ConnectionIndex = port_number
    
    local bytes = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(hHub, C.IOCTL_USB_HUB_CYCLE_PORT, cycle_params, ffi.sizeof(cycle_params), cycle_params, ffi.sizeof(cycle_params), bytes, nil)
    
    kernel32.CloseHandle(hHub)
    
    if res == 0 then return false, "Cycle Port IOCTL failed: " .. util.format_error() end
    
    return true
end

return M