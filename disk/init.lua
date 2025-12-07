local M = {}

local sub_modules = {
    physical  = 'win-utils.disk.physical',
    layout    = 'win-utils.disk.layout',
    geometry  = 'win-utils.disk.geometry',
    mount     = 'win-utils.disk.mount',
    format    = 'win-utils.disk.format',
    -- [REMOVED] vds
    vhd       = 'win-utils.disk.vhd',
    surface   = 'win-utils.disk.surface', 
    image     = 'win-utils.disk.image',
    esp       = 'win-utils.disk.esp',
    defs      = 'win-utils.disk.defs',
    types     = 'win-utils.disk.types',
    bitlocker = 'win-utils.disk.bitlocker',
    volume    = 'win-utils.disk.volume',
    safety    = 'win-utils.disk.safety',
    info      = 'win-utils.disk.info'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        
        -- [Compat] Compatibility Aliases
        if key == "list" then
            local vol = require('win-utils.disk.volume')
            rawset(t, "list", vol.list_letters)
            return vol.list_letters
        end
        if key == "info" then
            local info_mod = require('win-utils.disk.info')
            rawset(t, "info", info_mod.get)
            return info_mod.get
        end
        return nil
    end
})

-- [Helper] Wait for kernel PnP to recognize volumes on a disk
local function wait_for_partitions(drive_index, timeout)
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local volume = require 'win-utils.disk.volume'
    
    local start = kernel32.GetTickCount()
    local limit = timeout or 15000 
    
    while true do
        local vols = volume.list()
        if vols then
            for _, v in ipairs(vols) do
                local hVol = volume.open(v.guid_path)
                if hVol then
                    local defs = require 'win-utils.disk.defs'
                    local util = require 'win-utils.core.util'
                    local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
                    hVol:close()
                    
                    if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == drive_index then
                        return true -- Volumes appeared!
                    end
                end
            end
        end
        if (kernel32.GetTickCount() - start) > limit then return false end
        kernel32.Sleep(250)
    end
end

function M.prepare_drive(drive_index, scheme, opts)
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local layout = require 'win-utils.disk.layout'
    local device = require 'win-utils.device'
    local defs = require 'win-utils.disk.defs'

    -- 1. Unmount everything to release handles
    mount.unmount_all(drive_index)
    
    local drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    -- 2. Aggressive Lock
    if not drive:lock(true) then 
        drive:close()
        -- Try Hardware/Software Reset if software lock fails
        device.reset(drive_index, 2000)
        drive, err = physical.open(drive_index, "rw", true)
        if not drive then return false, "Re-open after reset failed" end
        if not drive:lock(true) then
            drive:close(); return false, "Lock failed after reset"
        end
    end
    
    -- 3. Clean (Replacing VDS Clean with IOCTL RAW)
    drive:wipe_layout() -- Wipe sectors 0 and end
    local clean_ok, clean_err = layout.clean(drive) -- Set partition style to RAW
    if not clean_ok then
        drive:close()
        return false, "Layout Clean failed: " .. tostring(clean_err)
    end
    
    -- 4. Apply New Layout
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok, apply_err = layout.apply(drive, scheme, plan)
    
    -- 5. Commit & Refresh
    drive:flush()
    drive:ioctl(defs.IOCTL.UPDATE) -- Force kernel update
    drive:close()
    
    if not ok then return false, "Layout apply failed: " .. tostring(apply_err) end

    -- 6. Wait for PnP (Replacing VDS Refresh)
    if not wait_for_partitions(drive_index, 10000) then
        return false, "Partition polling timed out (Volumes did not arrive)"
    end
    
    return true, plan
end

function M.clean_all(drive_index, cb)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    
    mount.unmount_all(drive_index)
    local drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local locked, lock_err = drive:lock(true)
    if not locked then 
        drive:close()
        return false, "Lock failed: " .. tostring(lock_err) 
    end
    
    local ok, w_err = drive:wipe_zero(cb)
    drive:close()
    
    return ok, w_err
end

function M.check_health(drive_index, cb, write_test)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local surface = require 'win-utils.disk.surface'
    
    if write_test then mount.unmount_all(drive_index) end
    local mode = write_test and "rw" or "r"
    
    local drive, err = physical.open(drive_index, mode, true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    if not drive:lock(true) then 
        drive:close()
        return false, "Lock failed" 
    end
    
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg, stats = surface.scan(drive, cb, write_test and "write" or "read", patterns)
    drive:close()
    return ok, msg, stats
end

function M.sync()
    local volume = require 'win-utils.disk.volume'
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local list = volume.list()
    if not list then return end
    for _, v in ipairs(list) do
        local h = volume.open(v.guid_path, true)
        if h then
            kernel32.FlushFileBuffers(h:get())
            h:close()
        end
    end
end

return M