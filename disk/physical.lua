local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local class = require 'win-utils.deps'.class
local proc_handles = require 'win-utils.process.handles'
local proc = require 'win-utils.process.init'
local table_new = require "table.new"

local PhysicalDrive = class()
local GUID_DISK = ffi.new("GUID", {0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}})

function PhysicalDrive:init(index, mode, exclusive)
    self.path = type(index) == "number" and ("\\\\.\\PhysicalDrive" .. index) or index
    self.index = type(index) == "number" and index or nil
    
    local h, err = native.open_device_robust(self.path, mode, exclusive)
    if not h then error("PhysicalDrive open failed: " .. tostring(err)) end
    
    self.obj = h
    self.handle = h:get()
    self.sector_size = 512
    self.size = 0
    
    self:update_geometry()
end

function PhysicalDrive:get() return self.handle end

function PhysicalDrive:close()
    if self.handle then
        if self.is_locked then self:unlock() end
        self.obj:close()
        self.handle = nil
    end
end

function PhysicalDrive:ioctl(code, in_obj, in_size, out_type, out_size)
    return util.ioctl(self.handle, code, in_obj, in_size, out_type, out_size)
end

function PhysicalDrive:update_geometry()
    local geo = self:ioctl(defs.IOCTL.GET_GEO, nil, 0, "DISK_GEOMETRY_EX")
    if geo then
        self.sector_size = tonumber(geo.Geometry.BytesPerSector)
        self.size = tonumber(geo.DiskSize.QuadPart)
    end
end

function PhysicalDrive:refresh()
    local ok, err = self:ioctl(defs.IOCTL.UPDATE)
    return ok
end

function PhysicalDrive:lock(force)
    local ok, err, code = self:ioctl(defs.IOCTL.DASD)
    if not ok and tonumber(code) == 5 then 
        return false, "DASD Access Denied: " .. tostring(err)
    end
    
    local attempts = 0
    local max_attempts = 50 
    
    ::retry::
    attempts = attempts + 1
    
    local l_ok, l_err, l_code = self:ioctl(defs.IOCTL.LOCK)
    if l_ok or l_code == 87 or l_code == 1 or l_code == 50 then
        self.is_locked = true
        return true
    end
    
    if attempts >= max_attempts then
        return false, "Lock Timeout: " .. tostring(l_err)
    end
    
    if force and (attempts % 10 == 0) then
        local pids = proc_handles.find_lockers(self.path)
        for _, pid in ipairs(pids) do proc.terminate(pid) end
    end
    
    self:ioctl(defs.IOCTL.DISMOUNT)
    kernel32.Sleep(100)
    goto retry
end

function PhysicalDrive:unlock()
    if self.is_locked then 
        self:ioctl(defs.IOCTL.UNLOCK)
        self.is_locked = false 
    end
end

function PhysicalDrive:wipe_zero(progress_cb)
    local buf_size = 1024 * 1024
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 0x04)
    if not buf then return false, "VirtualAlloc failed" end
    
    local total = self.size
    local processed = 0
    local written = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    
    li.QuadPart = 0
    kernel32.SetFilePointerEx(self.handle, li, nil, 0)
    
    local ok = true
    local err = nil
    
    while processed < total do
        local chunk = math.min(buf_size, total - processed)
        if chunk % self.sector_size ~= 0 then 
            chunk = math.ceil(chunk / self.sector_size) * self.sector_size 
        end
        
        if kernel32.WriteFile(self.handle, buf, chunk, written, nil) == 0 then
            ok = false; err = util.last_error("Write failed"); break
        end
        
        processed = processed + written[0]
        if progress_cb then
            if not progress_cb(processed / total) then ok = false; err = "Cancelled"; break end
        end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    self:refresh()
    return ok, err
end

function PhysicalDrive:wipe_layout()
    local wipe_size = 1024 * 1024
    local written = ffi.new("DWORD[1]")
    local buf = kernel32.VirtualAlloc(nil, wipe_size, 0x1000, 0x04)
    if not buf then return false, "Alloc failed" end
    
    local li = ffi.new("LARGE_INTEGER")
    li.QuadPart = 0
    kernel32.SetFilePointerEx(self.handle, li, nil, 0)
    kernel32.WriteFile(self.handle, buf, wipe_size, written, nil)
    
    if self.size > wipe_size then
        li.QuadPart = math.floor((self.size - wipe_size) / self.sector_size) * self.sector_size
        kernel32.SetFilePointerEx(self.handle, li, nil, 0)
        kernel32.WriteFile(self.handle, buf, wipe_size, written, nil)
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    self:refresh()
    return true
end

function PhysicalDrive:get_attributes()
    local attr, err = self:ioctl(defs.IOCTL.GET_ATTRIBUTES, nil, 0, "GET_DISK_ATTRIBUTES")
    if not attr then return nil, err end
    local f = tonumber(attr.Attributes)
    return { offline = bit.band(f, 1) ~= 0, read_only = bit.band(f, 2) ~= 0 }
end

function PhysicalDrive:set_attributes(attrs)
    local set_attr = ffi.new("SET_DISK_ATTRIBUTES")
    set_attr.Version = ffi.sizeof(set_attr); set_attr.Persist = 1
    local mask, val = 0, 0
    if attrs.read_only ~= nil then 
        mask = bit.bor(mask, 2); if attrs.read_only then val = bit.bor(val, 2) end 
    end
    if attrs.offline ~= nil then 
        mask = bit.bor(mask, 1); if attrs.offline then val = bit.bor(val, 1) end 
    end
    set_attr.AttributesMask = mask; set_attr.Attributes = val
    
    local ok, err = self:ioctl(defs.IOCTL.SET_ATTRIBUTES, set_attr)
    if not ok then return false, err end
    self:refresh()
    return true
end

function PhysicalDrive:write(offset, data, len)
    if offset % self.sector_size ~= 0 then return false, "Offset not aligned" end
    local ptr, raw_size
    if type(data) == "string" then ptr = ffi.cast("const void*", data); raw_size = #data
    else ptr = data; raw_size = len end
    local padding = 0
    if raw_size % self.sector_size ~= 0 then padding = self.sector_size - (raw_size % self.sector_size) end
    local aligned_size = raw_size + padding
    local buf = kernel32.VirtualAlloc(nil, aligned_size, 0x1000, 0x04)
    if not buf then return false, "Alloc failed" end
    ffi.copy(buf, ptr, raw_size)
    if padding > 0 then ffi.fill(ffi.cast("uint8_t*", buf) + raw_size, padding, 0) end
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = offset
    local ok = false; local msg
    if kernel32.SetFilePointerEx(self.handle, li, nil, 0) ~= 0 then
        local w = ffi.new("DWORD[1]")
        if kernel32.WriteFile(self.handle, buf, aligned_size, w, nil) ~= 0 then ok = true
        else msg = util.last_error("WriteFile failed") end
    else msg = util.last_error("Seek failed") end
    kernel32.VirtualFree(buf, 0, 0x8000)
    return ok, msg
end
PhysicalDrive.write_sectors = PhysicalDrive.write

function PhysicalDrive:read(offset, size)
    if offset % self.sector_size ~= 0 then return nil, "Offset not aligned" end
    local aligned_size = size
    if size % self.sector_size ~= 0 then aligned_size = math.ceil(size / self.sector_size) * self.sector_size end
    local buf = kernel32.VirtualAlloc(nil, aligned_size, 0x1000, 0x04)
    if not buf then return nil, "Alloc failed" end
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = offset
    local res = nil; local err
    if kernel32.SetFilePointerEx(self.handle, li, nil, 0) ~= 0 then
        local r = ffi.new("DWORD[1]")
        if kernel32.ReadFile(self.handle, buf, aligned_size, r, nil) ~= 0 then
            res = ffi.string(buf, math.min(size, r[0]))
        else err = util.last_error("ReadFile failed") end
    else err = util.last_error("Seek failed") end
    kernel32.VirtualFree(buf, 0, 0x8000)
    return res, err
end
PhysicalDrive.read_sectors = PhysicalDrive.read

-- [Rufus Port] Helper to robustly get drive index
local function get_drive_index(h)
    -- Strategy 1: IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS (Preferred by Rufus for external drives)
    local ext = util.ioctl(h, defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    if ext and ext.NumberOfDiskExtents > 0 then
        if ext.NumberOfDiskExtents > 1 then return -2 end -- RAID/Spanned (Ignore)
        return tonumber(ext.Extents[0].DiskNumber)
    end
    
    -- Strategy 2: IOCTL_STORAGE_GET_DEVICE_NUMBER (Fallback)
    local num = util.ioctl(h, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
    if num then return tonumber(num.DeviceNumber) end
    
    return -1
end

local function get_desc(h)
    local q = ffi.new("STORAGE_PROPERTY_QUERY"); q.PropertyId = 0; q.QueryType = 0
    local hdr = util.ioctl(h, defs.IOCTL.QUERY_PROP, q, nil, "STORAGE_DESCRIPTOR_HEADER")
    if not hdr then return nil end
    local buf = ffi.new("uint8_t[?]", hdr.Size)
    if not util.ioctl(h, defs.IOCTL.QUERY_PROP, q, nil, buf, hdr.Size) then return nil end
    local desc = ffi.cast("STORAGE_DEVICE_DESCRIPTOR*", buf)
    local function s(o) return o>0 and ffi.string(ffi.cast("char*", desc)+o):match("^%s*(.-)%s*$") or nil end
    local bus_map = {[7]="USB", [11]="SATA", [17]="NVMe"}
    return {
        vendor=s(desc.VendorIdOffset), product=s(desc.ProductIdOffset), serial=s(desc.SerialNumberOffset),
        bus=bus_map[tonumber(desc.BusType)] or "Unknown", removable=(desc.RemovableMedia~=0)
    }
end

function PhysicalDrive.list()
    local drives = table_new(4, 0)
    local hInfo = setupapi.SetupDiGetClassDevsW(GUID_DISK, nil, nil, 0x12)
    if hInfo == ffi.cast("HANDLE", -1) then return drives end
    local dev = ffi.new("SP_DEVINFO_DATA"); dev.cbSize = ffi.sizeof(dev)
    local iface = ffi.new("SP_DEVICE_INTERFACE_DATA"); iface.cbSize = ffi.sizeof(iface)
    local i = 0; local req = ffi.new("DWORD[1]")
    local buf, det, h, num, geo
    ::next_dev::
    if setupapi.SetupDiEnumDeviceInfo(hInfo, i, dev) == 0 then goto done end
    if setupapi.SetupDiEnumDeviceInterfaces(hInfo, dev, GUID_DISK, 0, iface) == 0 then i=i+1; goto next_dev end
    setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, nil, 0, req, nil)
    if req[0] == 0 then i=i+1; goto next_dev end
    buf = ffi.new("uint8_t[?]", req[0])
    det = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf); det.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
    if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, det, req[0], nil, nil) ~= 0 then
        h = kernel32.CreateFileW(det.DevicePath, 0, 3, nil, 3, 0, nil)
        if h ~= ffi.cast("HANDLE", -1) then
            -- [FIX] Use robust drive index logic ported from Rufus
            local idx = get_drive_index(h)
            if idx >= 0 then
                geo = util.ioctl(h, defs.IOCTL.GET_GEO, nil, 0, "DISK_GEOMETRY_EX")
                if geo then
                    local desc = get_desc(h)
                    table.insert(drives, {
                        index = idx,
                        path = "\\\\.\\PhysicalDrive"..idx,
                        model = (desc and desc.product) and (desc.vendor and desc.vendor.." " or "")..desc.product or "Generic Disk",
                        size = tonumber(geo.DiskSize.QuadPart),
                        sector_size = tonumber(geo.Geometry.BytesPerSector),
                        bus = desc and desc.bus or "Unknown"
                    })
                end
            end
            kernel32.CloseHandle(h)
        end
    end
    i = i + 1; goto next_dev
    ::done::
    setupapi.SetupDiDestroyDeviceInfoList(hInfo)
    return drives
end

local M = {}
function M.open(idx, mode, excl)
    local ok, res = pcall(function() return PhysicalDrive(idx, mode, excl) end)
    if not ok then return nil, res end
    return res
end
function M.list() return PhysicalDrive.list() end
return M