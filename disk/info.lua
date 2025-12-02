local ffi = require 'ffi'
local bit = require 'bit'
local defs = require 'win-utils.disk.defs'
local util = require 'win-utils.util'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}

local GUID_DEVINTERFACE_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})

local function extract_desc_str(buf_ptr, offset)
    if offset == 0 then return nil end
    local str_start = ffi.cast("char*", buf_ptr) + offset
    return ffi.string(str_start)
end

local function get_storage_descriptor(hDevice)
    local query = ffi.new("STORAGE_PROPERTY_QUERY")
    query.PropertyId = 0 
    query.QueryType = 0 
    
    local desc_header = ffi.new("STORAGE_DEVICE_DESCRIPTOR")
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(hDevice, defs.IOCTL.STORAGE_QUERY_PROPERTY, 
        query, ffi.sizeof(query), desc_header, ffi.sizeof(desc_header), bytes, nil) == 0 then
        return nil
    end

    local buf = ffi.new("uint8_t[?]", desc_header.Size)
    if kernel32.DeviceIoControl(hDevice, defs.IOCTL.STORAGE_QUERY_PROPERTY, 
        query, ffi.sizeof(query), buf, desc_header.Size, bytes, nil) == 0 then
        return nil
    end

    local desc = ffi.cast("STORAGE_DEVICE_DESCRIPTOR*", buf)
    local info = {
        bus_type = defs.BUS_TYPE[tonumber(desc.BusType)] or "Unknown",
        removable = (desc.RemovableMedia ~= 0),
        vendor = extract_desc_str(desc, desc.VendorIdOffset),
        product = extract_desc_str(desc, desc.ProductIdOffset),
        serial = extract_desc_str(desc, desc.SerialNumberOffset)
    }
    
    if info.vendor then info.vendor = info.vendor:match("^%s*(.-)%s*$") end
    if info.product then info.product = info.product:match("^%s*(.-)%s*$") end
    if info.serial then info.serial = info.serial:match("^%s*(.-)%s*$") end
    
    return info
end

local function get_geometry(hDevice)
    local geo = ffi.new("DISK_GEOMETRY_EX")
    local bytes = ffi.new("DWORD[1]")
    if kernel32.DeviceIoControl(hDevice, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, 
        nil, 0, geo, ffi.sizeof(geo), bytes, nil) == 0 then
        return nil
    end
    return {
        size = tonumber(geo.DiskSize.QuadPart),
        sector_size = tonumber(geo.Geometry.BytesPerSector),
        media_type = tonumber(geo.Geometry.MediaType)
    }
end

function M.list_physical_drives()
    local drives = {}
    local flags = bit.bor(0x02, 0x10)
    local hDevInfo = setupapi.SetupDiGetClassDevsW(GUID_DEVINTERFACE_DISK, nil, nil, flags)
    
    if hDevInfo == ffi.cast("void*", -1) then return {} end

    local devInfoData = ffi.new("SP_DEVINFO_DATA")
    devInfoData.cbSize = ffi.sizeof(devInfoData)
    local idx = 0

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
                    local devPathStr = util.from_wide(pDetail.DevicePath)
                    local hDev = kernel32.CreateFileW(pDetail.DevicePath, 0, bit.bor(1,2), nil, 3, 0, nil)
                    
                    if hDev ~= ffi.cast("HANDLE", -1) then
                        local num_buf = ffi.new("STORAGE_DEVICE_NUMBER")
                        local bytes = ffi.new("DWORD[1]")
                        local disk_num = -1
                        if kernel32.DeviceIoControl(hDev, defs.IOCTL.STORAGE_GET_DEVICE_NUMBER, nil, 0, num_buf, ffi.sizeof(num_buf), bytes, nil) ~= 0 then
                            disk_num = tonumber(num_buf.DeviceNumber)
                        end
                        
                        local desc = get_storage_descriptor(hDev)
                        local geo = get_geometry(hDev)
                        
                        kernel32.CloseHandle(hDev)

                        if disk_num >= 0 and geo then
                            local model_name = "Unknown Disk"
                            if desc and desc.vendor and desc.product then
                                model_name = desc.vendor .. " " .. desc.product
                            end

                            table.insert(drives, {
                                index = disk_num,
                                path = string.format("\\\\.\\PhysicalDrive%d", disk_num),
                                model = model_name,
                                bus_type = desc and desc.bus_type or "Unknown",
                                size = geo.size,
                                sector_size = geo.sector_size,
                                interface_path = devPathStr
                            })
                        end
                    end
                end
            end
        end
        idx = idx + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hDevInfo)
    return drives
end

return M