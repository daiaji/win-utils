local M = {}

local sub_modules = {
    physical  = 'win-utils.disk.physical',
    layout    = 'win-utils.disk.layout',
    geometry  = 'win-utils.disk.geometry',
    mount     = 'win-utils.disk.mount',
    format    = 'win-utils.disk.format',
    vds       = 'win-utils.disk.vds',
    vhd       = 'win-utils.disk.vhd',
    badblocks = 'win-utils.disk.badblocks',
    image     = 'win-utils.disk.image',
    esp       = 'win-utils.disk.esp',
    defs      = 'win-utils.disk.defs',
    types     = 'win-utils.disk.types',
    bitlocker = 'win-utils.disk.bitlocker',
    volume    = 'win-utils.disk.volume'
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
    
    local drive = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed" end
    if not drive:lock(true) then drive:close(); return false, "Lock failed" end
    
    local wiped = drive:wipe_layout()
    drive:close()
    if not wiped then return false, "Wipe layout failed" end
    
    vds.clean(drive_index)
    kernel32.Sleep(500)
    
    drive = physical.open(drive_index, "rw", true)
    if not drive then return false, "Re-open failed" end
    if not drive:lock(true) then drive:close(); return false, "Re-lock failed" end
    
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok = layout.apply(drive, scheme, plan)
    drive:close()
    
    kernel32.Sleep(1000)
    return ok, plan
end

function M.clean_all(drive_index, cb)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    
    mount.unmount_all_on_disk(drive_index)
    local drive = physical.open(drive_index, "rw", true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    
    local ok, err = drive:zero_fill(cb)
    
    drive:close()
    return ok, err
end

function M.check_health(drive_index, cb, write_test)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local badblocks = require 'win-utils.disk.badblocks'
    
    if write_test then mount.unmount_all_on_disk(drive_index) end
    local mode = write_test and "rw" or "r"
    local drive = physical.open(drive_index, mode, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg = badblocks.check(drive, cb, false, patterns)
    drive:close()
    return ok, msg
end

function M.rescan()
    local vds = require 'win-utils.disk.vds'
    local ctx = vds.create_context()
    if ctx then
        if ctx.service then
            ctx.service.lpVtbl.Refresh(ctx.service)
            ctx.service.lpVtbl.Reenumerate(ctx.service)
        end
        ctx:close()
        return true
    end
    return false
end

-- [NEW] Sync All Volumes (Flush Cache)
function M.sync()
    local volume = require 'win-utils.disk.volume'
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    
    local list = volume.list()
    if not list then return end
    
    for _, v in ipairs(list) do
        -- Open volume for writing attributes (minimal access required for Flush)
        local h = volume.open(v.guid_path, true) -- write access needed
        if h then
            kernel32.FlushFileBuffers(h:get())
            h:close()
        end
    end
end

return M