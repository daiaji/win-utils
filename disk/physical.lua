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
    
    -- [Rufus Strategy] Robust Open
    -- 使用 "exclusive" 模式迫使驱动在 CreateFile 阶段就处理共享冲突
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

-- [Rufus Strategy] Aggressive Lock
-- 1. 尝试 DASD (忽略错误)
-- 2. 循环重试 Lock
-- 3. 失败时调用 Dismount 和 杀进程
function PhysicalDrive:lock(force)
    -- 很多 USB/VHD 驱动对 DASD 返回错误，但这不影响后续操作，Rufus 选择忽略
    self:ioctl(defs.IOCTL.DASD)
    
    local attempts = 0
    local max_attempts = 150
    local err_msg
    
    ::retry::
    attempts = attempts + 1
    
    if self:ioctl(defs.IOCTL.LOCK) then
        self.is_locked = true
        return true
    end
    
    if attempts >= max_attempts then
        err_msg = util.last_error("Lock Volume Timeout")
        goto fail
    end
    
    if (force and (attempts % 20 == 0)) or (attempts == 50) then
        local pids = proc_handles.find_lockers(self.path)
        for _, pid in ipairs(pids) do proc.terminate(pid) end
        if #pids > 0 then kernel32.Sleep(500) end
    end
    
    self:ioctl(defs.IOCTL.DISMOUNT)
    kernel32.Sleep(100)
    goto retry
    
    ::fail::
    return false, err_msg
end

function PhysicalDrive:unlock()
    if self.is_locked then 
        self:ioctl(defs.IOCTL.UNLOCK)
        self.is_locked = false 
    end
end

function PhysicalDrive:flush()
    if self.handle then
        kernel32.FlushFileBuffers(self.handle)
    end
end

-- [Rufus Strategy] Pre-Wipe / Ghost Data Cleaning
function PhysicalDrive:wipe_region(offset, size)
    local buf_size = 1024 * 1024
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 0x04)
    if not buf then return false, "VirtualAlloc failed" end
    
    local processed = 0
    local ok = true
    local err = nil
    
    while processed < size do
        local chunk = math.min(buf_size, size - processed)
        -- 对齐到扇区
        if chunk % self.sector_size ~= 0 then 
            chunk = math.ceil(chunk / self.sector_size) * self.sector_size 
        end
        
        -- 使用带重试的写入
        local w_ok, w_err = self:write(offset + processed, buf, chunk)
        if not w_ok then
            ok = false; err = w_err; break
        end
        
        processed = processed + chunk
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    return ok, err
end

function PhysicalDrive:wipe_zero(progress_cb)
    return self:wipe_region(0, self.size)
end

function PhysicalDrive:wipe_layout()
    local wipe_size = 8 * 1024 * 1024
    -- Wipe Start (MBR/GPT)
    local ok1 = self:wipe_region(0, wipe_size)
    -- Wipe End (Backup GPT)
    local ok2 = self:wipe_region(math.floor((self.size - 1024*1024) / self.sector_size) * self.sector_size, 1024*1024)
    return ok1 and ok2
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
        mask = bit.bor(mask, 2)
        if attrs.read_only then val = bit.bor(val, 2) end 
    end
    if attrs.offline ~= nil then 
        mask = bit.bor(mask, 1)
        if attrs.offline then val = bit.bor(val, 1) end 
    end
    set_attr.AttributesMask = mask; set_attr.Attributes = val
    
    local ok, err = self:ioctl(defs.IOCTL.SET_ATTRIBUTES, set_attr)
    if not ok then return false, err end
    
    self:ioctl(defs.IOCTL.UPDATE)
    return true
end

-- [Rufus Strategy] Stateful Write Retry
-- 1. 指针回滚 (Pointer Rollback): 写入失败后恢复文件指针
-- 2. 扇区对齐 (Alignment): 强制 Buffer 和长度对齐
-- 3. 退避重试 (Backoff): 短暂睡眠后重试
function PhysicalDrive:write(offset, data, len)
    if offset % self.sector_size ~= 0 then return false, "Offset not aligned" end
    
    local ptr, raw_size
    if type(data) == "string" then
        ptr = ffi.cast("const void*", data)
        raw_size = #data
    else
        ptr = data
        raw_size = len or error("Length required for cdata")
    end
    
    local padding = 0
    if raw_size % self.sector_size ~= 0 then 
        padding = self.sector_size - (raw_size % self.sector_size) 
    end
    
    local aligned_size = raw_size + padding
    local buf = kernel32.VirtualAlloc(nil, aligned_size, 0x1000, 0x04)
    if not buf then return false, "Alloc failed" end
    
    ffi.copy(buf, ptr, raw_size)
    if padding > 0 then ffi.fill(ffi.cast("uint8_t*", buf) + raw_size, padding, 0) end
    
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = offset
    local w_bytes = ffi.new("DWORD[1]")
    local ok = false
    local msg = nil
    
    local retries = 4
    for i=1, retries do
        -- 1. Set Pointer (每次重试都重置指针)
        if kernel32.SetFilePointerEx(self.handle, li, nil, 0) == 0 then
            msg = util.last_error("Seek failed")
            break
        end
        
        -- 2. Write
        if kernel32.WriteFile(self.handle, buf, aligned_size, w_bytes, nil) ~= 0 then
            if w_bytes[0] == aligned_size then
                ok = true
                break
            else
                msg = string.format("Short write: %d/%d", w_bytes[0], aligned_size)
            end
        else
            msg = util.last_error("WriteFile failed")
        end
        
        -- 3. Recover
        if i < retries then kernel32.Sleep(100) end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    return ok, msg
end

PhysicalDrive.write_sectors = PhysicalDrive.write

function PhysicalDrive:read(offset, size)
    if offset % self.sector_size ~= 0 then return nil, "Offset not aligned" end
    
    local aligned_size = size
    if size % self.sector_size ~= 0 then 
        aligned_size = math.ceil(size / self.sector_size) * self.sector_size 
    end
    
    local buf = kernel32.VirtualAlloc(nil, aligned_size, 0x1000, 0x04)
    if not buf then return nil, "Alloc failed" end
    
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = offset
    local res = nil
    local err
    
    if kernel32.SetFilePointerEx(self.handle, li, nil, 0) ~= 0 then
        local r = ffi.new("DWORD[1]")
        if kernel32.ReadFile(self.handle, buf, aligned_size, r, nil) ~= 0 then
            res = ffi.string(buf, math.min(size, r[0]))
        else
            err = util.last_error("ReadFile failed")
        end
    else
        err = util.last_error("Seek failed")
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    return res, err
end

PhysicalDrive.read_sectors = PhysicalDrive.read

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
    local i = 0
    
    local req = ffi.new("DWORD[1]")
    local buf, det, h, num, geo
    
    ::next_dev::
    if setupapi.SetupDiEnumDeviceInfo(hInfo, i, dev) == 0 then goto done end
    if setupapi.SetupDiEnumDeviceInterfaces(hInfo, dev, GUID_DISK, 0, iface) == 0 then
        i = i + 1; goto next_dev
    end
    
    setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, nil, 0, req, nil)
    if req[0] == 0 then i = i + 1; goto next_dev end
    
    buf = ffi.new("uint8_t[?]", req[0])
    det = ffi.cast("PSP_DEVICE_INTERFACE_DETAIL_DATA_W", buf)
    det.cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DETAIL_DATA_W")
    
    if setupapi.SetupDiGetDeviceInterfaceDetailW(hInfo, iface, det, req[0], nil, nil) ~= 0 then
        h = kernel32.CreateFileW(det.DevicePath, 0, 3, nil, 3, 0, nil)
        if h ~= ffi.cast("HANDLE", -1) then
            num = util.ioctl(h, defs.IOCTL.GET_NUM, nil, 0, "STORAGE_DEVICE_NUMBER")
            if num then
                geo = util.ioctl(h, defs.IOCTL.GET_GEO, nil, 0, "DISK_GEOMETRY_EX")
                if geo then
                    local desc = get_desc(h)
                    table.insert(drives, {
                        index = tonumber(num.DeviceNumber),
                        path = "\\\\.\\PhysicalDrive"..tonumber(num.DeviceNumber),
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
    i = i + 1
    goto next_dev
    
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