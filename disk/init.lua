local M = {}

local sub_modules = {
    physical  = 'win-utils.disk.physical',
    layout    = 'win-utils.disk.layout',
    geometry  = 'win-utils.disk.geometry',
    mount     = 'win-utils.disk.mount',
    format    = 'win-utils.disk.format',
    vds       = 'win-utils.disk.vds',
    vhd       = 'win-utils.disk.vhd',
    surface   = 'win-utils.disk.surface', 
    image     = 'win-utils.disk.image',
    esp       = 'win-utils.disk.esp',
    defs      = 'win-utils.disk.defs',
    types     = 'win-utils.disk.types',
    bitlocker = 'win-utils.disk.bitlocker',
    volume    = 'win-utils.disk.volume',
    safety    = 'win-utils.disk.safety'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

function M.prepare_drive(drive_index, scheme, opts)
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local vds = require 'win-utils.disk.vds'
    local layout = require 'win-utils.disk.layout'

    mount.unmount_all_on_disk(drive_index)
    
    local drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local locked, lock_err = drive:lock(true)
    if not locked then 
        drive:close()
        return false, "Lock failed: " .. tostring(lock_err) 
    end
    
    local wiped = drive:wipe_layout()
    drive:close()
    if not wiped then return false, "Wipe layout failed" end
    
    -- VDS Clean is robust for refreshing system view
    local v_ok, v_err = vds.clean(drive_index)
    if not v_ok then return false, "VDS Clean failed: " .. tostring(v_err) end
    
    kernel32.Sleep(500)
    
    -- Re-open for layout application
    drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Re-open failed: " .. tostring(err) end
    
    locked, lock_err = drive:lock(true)
    if not locked then 
        drive:close()
        return false, "Re-lock failed: " .. tostring(lock_err) 
    end
    
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok, apply_err = layout.apply(drive, scheme, plan)
    drive:close()
    
    if not ok then return false, "Layout apply failed: " .. tostring(apply_err) end
    
    kernel32.Sleep(1000)
    return true, plan
end

function M.clean_all(drive_index, cb)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    
    mount.unmount_all_on_disk(drive_index)
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
    
    if write_test then mount.unmount_all_on_disk(drive_index) end
    local mode = write_test and "rw" or "r"
    
    local drive, err = physical.open(drive_index, mode, true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    if not drive:lock(true) then 
        drive:close()
        return false, "Lock failed" 
    end
    
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg = surface.scan(drive, cb, write_test and "write" or "read", patterns)
    drive:close()
    return ok, msg
end

function M.rescan()
    -- VDS Refresh logic is internal or not fully exposed via helpers yet.
    -- Returning specific error instead of generic false.
    return false, "Not implemented via VDS helpers"
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