local ffi = require 'ffi'
local bit = require 'bit'
local defs = require 'win-utils.disk.defs'
local util = require 'win-utils.util'
local native = require 'win-utils.native'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local class = require 'win-utils.deps'.class
local proc_handle = require 'win-utils.process.handle'
local proc_utils = require 'win-utils.process'

local C = ffi.C
local PhysicalDrive = class()

function PhysicalDrive:init(index, write_access, exclusive)
    self.path = type(index) == "number" and ("\\\\.\\PhysicalDrive" .. index) or index
    
    -- [REFACTOR] Use centralized native opener
    local h, err = native.open_device(self.path, write_access, exclusive)
    if not h then error("Open failed: " .. tostring(err)) end
    
    self.obj = h
    self.handle = h:get() -- Cache raw handle for performance in tight loops
    
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

function PhysicalDrive:update_geometry()
    local geo = util.ioctl(self.handle, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, nil, 0, "DISK_GEOMETRY_EX")
    if geo then
        self.sector_size = tonumber(geo.Geometry.BytesPerSector)
        self.size = tonumber(geo.DiskSize.QuadPart)
    end
end

function PhysicalDrive:lock(force)
    util.ioctl(self.handle, defs.IOCTL.FSCTL_ALLOW_EXTENDED_DASD_IO)
    for i = 1, 150 do
        if util.ioctl(self.handle, defs.IOCTL.FSCTL_LOCK_VOLUME) then
            self.is_locked = true
            return true
        end
        if (force and (i % 20 == 0)) or (i == 50) then
            -- Lazy load to break circular dependency is handled by process module being lazy loaded in init
            local pids = proc_handle.find_locking_pids(self.path)
            for _, pid in ipairs(pids) do proc_utils.terminate_by_pid(pid) end
            if #pids > 0 then kernel32.Sleep(500) end
        end
        util.ioctl(self.handle, defs.IOCTL.FSCTL_DISMOUNT_VOLUME)
        kernel32.Sleep(100)
    end
    return false, util.format_error()
end

function PhysicalDrive:unlock()
    if self.is_locked then 
        util.ioctl(self.handle, defs.IOCTL.FSCTL_UNLOCK_VOLUME)
        self.is_locked = false 
    end
end

function PhysicalDrive:wipe_layout()
    local wipe_size = 8 * 1024 * 1024
    local written = ffi.new("DWORD[1]")
    local pMem = kernel32.VirtualAlloc(nil, wipe_size, 0x1000, 0x04)
    if not pMem then return false end
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    local success = true
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = 0
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) ~= 0 then
        if kernel32.WriteFile(self.handle, pMem, wipe_size, written, nil) == 0 then success = false end
    end
    
    if success and self.size > wipe_size/8 then
        li.QuadPart = math.floor((self.size - wipe_size/8) / self.sector_size) * self.sector_size
        if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) ~= 0 then
            kernel32.WriteFile(self.handle, pMem, wipe_size/8, written, nil)
        end
    end
    ffi.gc(pMem, nil); kernel32.VirtualFree(pMem, 0, 0x8000)
    return success
end

function PhysicalDrive:zero_fill(progress_cb)
    local buf_size = 1024 * 1024
    local pMem = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 0x04)
    if not pMem then return false end
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = 0
    kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN)
    
    local written, processed = ffi.new("DWORD[1]"), 0
    local success = true
    
    while processed < self.size do
        local chunk = math.min(buf_size, self.size - processed)
        if chunk % self.sector_size ~= 0 then 
            chunk = math.ceil(chunk / self.sector_size) * self.sector_size 
        end
        if kernel32.WriteFile(self.handle, pMem, chunk, written, nil) == 0 then success = false; break end
        processed = processed + written[0]
        if progress_cb and not progress_cb(processed / self.size) then success = false; break end
    end
    ffi.gc(pMem, nil); kernel32.VirtualFree(pMem, 0, 0x8000)
    return success
end

function PhysicalDrive:get_attributes()
    local attr = util.ioctl(self.handle, defs.IOCTL.DISK_GET_DISK_ATTRIBUTES, nil, 0, "GET_DISK_ATTRIBUTES")
    if not attr then return nil, util.format_error() end
    local f = tonumber(attr.Attributes)
    return { offline = bit.band(f, defs.DISK_ATTRIBUTE.OFFLINE) ~= 0, read_only = bit.band(f, defs.DISK_ATTRIBUTE.READ_ONLY) ~= 0 }
end

function PhysicalDrive:set_attributes(attrs)
    local set_attr = ffi.new("SET_DISK_ATTRIBUTES")
    set_attr.Version = ffi.sizeof(set_attr); set_attr.Persist = 1
    local mask, val = 0, 0
    if attrs.read_only ~= nil then mask = bit.bor(mask, defs.DISK_ATTRIBUTE.READ_ONLY); if attrs.read_only then val = bit.bor(val, defs.DISK_ATTRIBUTE.READ_ONLY) end end
    if attrs.offline ~= nil then mask = bit.bor(mask, defs.DISK_ATTRIBUTE.OFFLINE); if attrs.offline then val = bit.bor(val, defs.DISK_ATTRIBUTE.OFFLINE) end end
    set_attr.AttributesMask = mask; set_attr.Attributes = val
    if not util.ioctl(self.handle, defs.IOCTL.DISK_SET_DISK_ATTRIBUTES, set_attr) then return false, util.format_error() end
    util.ioctl(self.handle, defs.IOCTL.DISK_UPDATE_PROPERTIES)
    return true
end

function PhysicalDrive:io_op(offset, data_or_size, is_write)
    local size = is_write and #data_or_size or data_or_size
    if offset % self.sector_size ~= 0 or size % self.sector_size ~= 0 then return nil, "Alignment error" end
    
    local buf = kernel32.VirtualAlloc(nil, size, 0x1000, 0x04)
    if not buf then return nil, "Alloc failed" end
    ffi.gc(buf, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    if is_write then ffi.copy(buf, data_or_size, size) end
    local li = ffi.new("LARGE_INTEGER"); li.QuadPart = offset
    
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) == 0 then return nil, "Seek failed" end
    local rw_bytes = ffi.new("DWORD[1]")
    local res = is_write and kernel32.WriteFile(self.handle, buf, size, rw_bytes, nil) or kernel32.ReadFile(self.handle, buf, size, rw_bytes, nil)
    
    local ret = nil
    if res ~= 0 and rw_bytes[0] == size then ret = is_write and true or ffi.string(buf, size) end
    ffi.gc(buf, nil); kernel32.VirtualFree(buf, 0, 0x8000)
    return ret
end

function PhysicalDrive:write_sectors(o, d) return self:io_op(o, d, true) end
function PhysicalDrive:read_sectors(o, s) return self:io_op(o, s, false) end

-- Return class directly, caller uses PhysicalDrive(idx)
return PhysicalDrive