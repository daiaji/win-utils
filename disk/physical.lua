local ffi = require 'ffi'
local bit = require 'bit'
local defs = require 'win-utils.disk.defs'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local proc_handle = require 'win-utils.process.handle'
local proc_utils = require 'win-utils.process' 

local M = {}
local PhysicalDrive = {}
PhysicalDrive.__index = PhysicalDrive

local C = ffi.C

-- Ported from Rufus drive.c: GetHandle()
-- Enhanced with 150 retries / 15000ms timeout
function M.open(index_or_path, write_access, exclusive)
    local path
    if type(index_or_path) == "number" then
        path = string.format("\\\\.\\PhysicalDrive%d", index_or_path)
    else
        path = index_or_path
    end

    -- [OPTIMIZATION] Convert path once to avoid GC pressure in retry loop
    local w_path = util.to_wide(path)

    local access = C.GENERIC_READ
    if write_access then
        access = bit.bor(access, C.GENERIC_WRITE)
    end
    
    -- FILE_SHARE_READ | (bWriteShare ? FILE_SHARE_WRITE : 0)
    local share = C.FILE_SHARE_READ
    if not exclusive then
        share = bit.bor(share, C.FILE_SHARE_WRITE)
    end

    local create_disp = C.OPEN_EXISTING
    -- FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH
    local flags = bit.bor(C.FILE_ATTRIBUTE_NORMAL, C.FILE_FLAG_NO_BUFFERING, C.FILE_FLAG_WRITE_THROUGH)

    local h = ffi.cast("HANDLE", -1)
    
    -- Rufus Constants: 150 retries, 15000ms total timeout
    -- Interval ~= 100ms
    local retries = 150
    local timeout_total = 15000 
    local sleep_interval = math.floor(timeout_total / retries)
    
    for i = 1, retries do
        -- Use pre-converted wide string
        h = kernel32.CreateFileW(w_path, access, share, nil, create_disp, flags, nil)
        
        if h ~= ffi.cast("HANDLE", -1) then break end
        
        local err = kernel32.GetLastError()
        if err ~= 32 and err ~= 5 then -- ERROR_SHARING_VIOLATION / ACCESS_DENIED
            break
        end
        
        -- Fallback strategy: If we can't get exclusive after 1/3 of the time, try shared write
        if exclusive and i > (retries / 3) then
            exclusive = false
            share = bit.bor(share, C.FILE_SHARE_WRITE)
        end
        
        kernel32.Sleep(sleep_interval)
    end
    
    if h == ffi.cast("HANDLE", -1) then
        return nil, util.format_error()
    end

    local self = setmetatable({
        handle = Handle.guard(h),
        path = path,
        sector_size = 512,
        size = 0,
        is_locked = false
    }, PhysicalDrive)

    self:update_geometry()
    return self
end

function PhysicalDrive:update_geometry()
    local geo = ffi.new("DISK_GEOMETRY_EX")
    local bytes = ffi.new("DWORD[1]")
    if kernel32.DeviceIoControl(self.handle, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, 
        nil, 0, geo, ffi.sizeof(geo), bytes, nil) ~= 0 then
        self.sector_size = tonumber(geo.Geometry.BytesPerSector)
        self.size = tonumber(geo.DiskSize.QuadPart)
    end
end

-- Ported from Rufus drive.c: locking logic
-- [ENHANCED] Added `force` parameter to kill locking processes
function PhysicalDrive:lock(force)
    if self.is_locked then return true end
    
    kernel32.DeviceIoControl(self.handle, defs.IOCTL.FSCTL_ALLOW_EXTENDED_DASD_IO, nil, 0, nil, 0, nil, nil)

    -- Rufus uses the same 150 retry loop logic for locking
    local retries = 150
    local timeout_total = 15000 
    local sleep_interval = math.floor(timeout_total / retries)
    local success = false
    local bytes = ffi.new("DWORD[1]")
    
    for i = 1, retries do
        if kernel32.DeviceIoControl(self.handle, defs.IOCTL.FSCTL_LOCK_VOLUME, nil, 0, nil, 0, bytes, nil) ~= 0 then
            success = true
            break
        end
        
        -- [Handle Hunting]
        -- Check heavily at the beginning (retries/2 in original logic was for 20 retries)
        -- Rufus checks around 1/3 or if force is enabled
        if (force and (i % 20 == 0)) or (i == 50) then
            local pids = proc_handle.find_locking_pids(self.path)
            if #pids > 0 then
                if force then
                    for _, pid in ipairs(pids) do
                        proc_utils.terminate_by_pid(pid)
                    end
                    -- Wait a bit for processes to die
                    kernel32.Sleep(500) 
                end
            end
        end
        
        kernel32.DeviceIoControl(self.handle, defs.IOCTL.FSCTL_DISMOUNT_VOLUME, nil, 0, nil, 0, bytes, nil)
        kernel32.Sleep(sleep_interval)
    end

    if success then
        self.is_locked = true
        return true
    end
    
    return false, util.format_error()
end

function PhysicalDrive:unlock()
    if not self.is_locked then return end
    local bytes = ffi.new("DWORD[1]")
    kernel32.DeviceIoControl(self.handle, defs.IOCTL.FSCTL_UNLOCK_VOLUME, nil, 0, nil, 0, bytes, nil)
    self.is_locked = false
end

-- Ported from Rufus format.c: ClearMBRGPT()
-- Wipes the beginning and end of the drive to remove partition tables.
function PhysicalDrive:wipe_layout()
    local wipe_size = 8 * 1024 * 1024 -- 8MB (Rufus MAX_SECTORS_TO_CLEAR * 512)
    local written = ffi.new("DWORD[1]")
    
    -- 1. Allocate Aligned Memory (Zero initialized by default in VirtualAlloc)
    local pMem = kernel32.VirtualAlloc(nil, wipe_size, 0x1000, 0x04) -- MEM_COMMIT, PAGE_READWRITE
    if pMem == nil then return false, "VirtualAlloc failed" end
    
    -- Ensure cleanup on return
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end) -- MEM_RELEASE

    local success = true
    local msg = nil

    -- 2. Wipe Start (MBR + Primary GPT)
    local li = ffi.new("LARGE_INTEGER")
    li.QuadPart = 0
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) == 0 then
        success = false; msg = "Seek Start Failed"
    else
        if kernel32.WriteFile(self.handle, pMem, wipe_size, written, nil) == 0 then
            success = false; msg = "Wipe Start Failed: " .. util.format_error()
        end
    end
    
    -- 3. Wipe End (Backup GPT)
    -- Rufus wipes (MAX_SECTORS_TO_CLEAR / 8) at the end = 1MB
    local end_wipe_size = wipe_size / 8
    
    if success and self.size > end_wipe_size then
        li.QuadPart = self.size - end_wipe_size
        -- We align the offset to sector size just in case
        local sector_aligned_offset = math.floor(self.size / self.sector_size) * self.sector_size - end_wipe_size
        li.QuadPart = sector_aligned_offset
        
        if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) ~= 0 then
            -- We ignore errors at the very end of the disk as some drives report size slightly incorrectly
            kernel32.WriteFile(self.handle, pMem, end_wipe_size, written, nil)
        end
    end
    
    -- Release memory immediately
    ffi.gc(pMem, nil)
    kernel32.VirtualFree(pMem, 0, 0x8000)
    
    if not success then return false, msg end
    return true
end

-- clean all implementation
-- Writes zeros to the entire disk surface
-- @param progress_cb: function(percent) return bool (true to continue)
function PhysicalDrive:zero_fill(progress_cb)
    local buf_size = 1024 * 1024 -- 1MB Buffer
    
    -- Allocate aligned buffer
    local pMem = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 0x04)
    if pMem == nil then return false, "VirtualAlloc failed" end
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    -- Seek to start
    local li = ffi.new("LARGE_INTEGER")
    li.QuadPart = 0
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) == 0 then
        return false, "Seek failed"
    end
    
    local written = ffi.new("DWORD[1]")
    local total = self.size
    local processed = 0
    local success = true
    local err_msg = nil
    
    -- Main loop
    while processed < total do
        local to_write = math.min(buf_size, total - processed)
        
        -- Align to sector size if needed (last chunk)
        if to_write % self.sector_size ~= 0 then
            to_write = math.ceil(to_write / self.sector_size) * self.sector_size
        end
        
        if kernel32.WriteFile(self.handle, pMem, to_write, written, nil) == 0 then
            success = false
            err_msg = "Write failed at offset " .. processed .. ": " .. util.format_error()
            break
        end
        
        processed = processed + written[0]
        
        if progress_cb then
            if not progress_cb(processed / total) then
                success = false
                err_msg = "Cancelled by user"
                break
            end
        end
    end
    
    ffi.gc(pMem, nil)
    kernel32.VirtualFree(pMem, 0, 0x8000)
    
    if not success then return false, err_msg end
    return true
end

function PhysicalDrive:close()
    if self.handle then
        if self.is_locked then self:unlock() end
        Handle.close(self.handle)
        self.handle = nil
    end
end

function PhysicalDrive:get_attributes()
    local attr = ffi.new("GET_DISK_ATTRIBUTES")
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(self.handle, defs.IOCTL.DISK_GET_DISK_ATTRIBUTES, 
        nil, 0, attr, ffi.sizeof(attr), bytes, nil) == 0 then
        return nil, util.format_error()
    end
    
    local flags = tonumber(attr.Attributes)
    return {
        offline = bit.band(flags, defs.DISK_ATTRIBUTE.OFFLINE) ~= 0,
        read_only = bit.band(flags, defs.DISK_ATTRIBUTE.READ_ONLY) ~= 0
    }
end

function PhysicalDrive:set_attributes(attrs)
    local set_attr = ffi.new("SET_DISK_ATTRIBUTES")
    set_attr.Version = ffi.sizeof(set_attr)
    set_attr.Persist = 1
    
    local mask = 0
    local val = 0
    
    if attrs.read_only ~= nil then
        mask = bit.bor(mask, defs.DISK_ATTRIBUTE.READ_ONLY)
        if attrs.read_only then val = bit.bor(val, defs.DISK_ATTRIBUTE.READ_ONLY) end
    end
    
    if attrs.offline ~= nil then
        mask = bit.bor(mask, defs.DISK_ATTRIBUTE.OFFLINE)
        if attrs.offline then val = bit.bor(val, defs.DISK_ATTRIBUTE.OFFLINE) end
    end
    
    set_attr.AttributesMask = mask
    set_attr.Attributes = val
    
    local bytes = ffi.new("DWORD[1]")
    if kernel32.DeviceIoControl(self.handle, defs.IOCTL.DISK_SET_DISK_ATTRIBUTES, 
        set_attr, ffi.sizeof(set_attr), nil, 0, bytes, nil) == 0 then
        return false, util.format_error()
    end
    
    kernel32.DeviceIoControl(self.handle, defs.IOCTL.DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
    return true
end

function PhysicalDrive:write_sectors(offset, data)
    local size = #data
    if offset % self.sector_size ~= 0 or size % self.sector_size ~= 0 then
        return false, "Alignment error"
    end

    local li = ffi.new("LARGE_INTEGER")
    li.QuadPart = offset
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) == 0 then
        return false, "Seek failed"
    end

    -- Use VirtualAlloc for sector alignment requirements
    local pMem = kernel32.VirtualAlloc(nil, size, 0x1000, 0x04)
    if pMem == nil then return false, "VirtualAlloc failed" end
    
    ffi.copy(pMem, data, size)
    
    local written = ffi.new("DWORD[1]")
    local res = kernel32.WriteFile(self.handle, pMem, size, written, nil)
    
    kernel32.VirtualFree(pMem, 0, 0x8000)
    
    return res ~= 0 and written[0] == size
end

function PhysicalDrive:read_sectors(offset, size)
    if offset % self.sector_size ~= 0 or size % self.sector_size ~= 0 then
        return nil, "Offset/Size alignment error"
    end

    local buf = kernel32.VirtualAlloc(nil, size, 0x1000, 0x04)
    if buf == nil then return nil, "VirtualAlloc failed" end
    
    ffi.gc(buf, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)

    local li = ffi.new("LARGE_INTEGER")
    li.QuadPart = offset
    if kernel32.SetFilePointerEx(self.handle, li, nil, C.FILE_BEGIN) == 0 then
        return nil, "Seek failed"
    end

    local read = ffi.new("DWORD[1]")
    if kernel32.ReadFile(self.handle, buf, size, read, nil) == 0 then
        return nil, util.format_error()
    end

    if read[0] ~= size then return nil, "Short read" end

    local data = ffi.string(buf, size)
    ffi.gc(buf, nil) 
    kernel32.VirtualFree(buf, 0, 0x8000)

    return data
end

return M