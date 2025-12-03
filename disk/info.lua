local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'

local M = {}
local GUID_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})

local function get_desc(h)
    local q = ffi.new("STORAGE_PROPERTY_QUERY"); q.PropertyId = 0; q.QueryType = 0
    local hdr = util.ioctl(h, defs.IOCTL.STORAGE_QUERY_PROPERTY, q, nil, "STORAGE_DEVICE_DESCRIPTOR")
    if not hdr then return nil end
    
    -- [FIX] Explicitly allocate buffer. util.ioctl returns the buffer passed as 'out_type' (if cdata)
    local buf = ffi.new("uint8_t[?]", hdr.Size)
    if not util.ioctl(h, defs.IOCTL.STORAGE_QUERY_PROPERTY, q, nil, buf, hdr.Size) then 
        return nil 
    end
    
    local desc = ffi.cast("STORAGE_DEVICE_DESCRIPTOR*", buf)
    
    local function s(off) return off > 0 and ffi.string(ffi.cast("char*", desc) + off):match("^%s*(.-)%s*$") or nil end
    return {
        bus = defs.BUS_TYPE[tonumber(desc.BusType)] or "Unknown",
        removable = desc.RemovableMedia ~= 0,
        vendor = s(desc.VendorIdOffset), product = s(desc.ProductIdOffset), serial = s(desc.SerialNumberOffset)
    }
end

function M.list_physical_drives()
    local drives = {}
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, 0x12)
    if hInfo == ffi.cast("HANDLE", -1) then return {} end
    
    local devData = ffi.new("SP_DEVINFO_DATA"); devData.cbSize = ffi.sizeof(devData)
    local iface = ffi.new("SP_DEVICE_INTERFACE_DATA"); iface.cbSize = ffi.sizeof(iface)
    local i = 0
    
    while setupapi.SetupDiEnumDeviceInfo(hInfo, i, devData) ~= 0 do
        if setupapi.SetupDiEnumDeviceInterfaces(hInfo, devData, GUID_DISK, 0, iface) ~= 0 then
            local req = ffi.new("DWORD[1]")
            setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, nil, 0, req, nil)
            if req[0] > 0 then
                local buf = ffi.new("uint8_t[?]", req[0])
                local det = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
                det.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
                if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, det, req[0], nil, nil) ~= 0 then
                    local h = kernel32.CreateFileW(det.DevicePath, 0, 3, nil, 3, 0, nil)
                    if h ~= ffi.cast("HANDLE", -1) then
                        local num = util.ioctl(h, defs.IOCTL.STORAGE_GET_DEVICE_NUMBER, nil, 0, "STORAGE_DEVICE_NUMBER")
                        if num then
                            local geo = util.ioctl(h, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, nil, 0, "DISK_GEOMETRY_EX")
                            if geo then
                                local desc = get_desc(h)
                                local name = (desc and desc.vendor and desc.product) and (desc.vendor.." "..desc.product) or "Generic Disk"
                                table.insert(drives, {
                                    index = tonumber(num.DeviceNumber),
                                    path = "\\\\.\\PhysicalDrive"..tonumber(num.DeviceNumber),
                                    model = name,
                                    size = tonumber(geo.DiskSize.QuadPart),
                                    sector_size = tonumber(geo.Geometry.BytesPerSector),
                                    bus = desc and desc.bus or "Unknown"
                                })
                            end
                        end
                        kernel32.CloseHandle(h)
                    end
                end
            end
        end
        i = i + 1
    end
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return drives
end

return M