local ffi = require 'ffi'
local physical = require 'win-utils.disk.physical'
local layout = require 'win-utils.disk.layout'
local vds = require 'win-utils.disk.vds'
local fat32_lib = require 'win-utils.disk.format.fat32'
local format_lib = require 'win-utils.disk.format.fmifs'
local volume = require 'win-utils.disk.volume'
local badblocks = require 'win-utils.disk.badblocks'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local device = require 'win-utils.device'

local M = {}

function M.prepare_drive(drive_index, scheme, opts)
    -- 1. Unmount volumes to prevent locking issues
    volume.unmount_all_on_disk(drive_index)
    
    -- 2. Wipe Layout (Manual)
    -- We open, lock, wipe, then CLOSE. This ensures VDS can access the drive later.
    local drive = physical.open(drive_index, true, true)
    if not drive then return false, "Open failed" end
    
    if not drive:lock(true) then 
        drive:close()
        return false, "Lock failed" 
    end
    
    local wiped = drive:wipe_layout()
    drive:close() -- CRITICAL: Release lock for VDS
    
    if not wiped then return false, "Wipe layout failed" end
    
    -- 3. VDS Clean (Optional but recommended for system refresh)
    -- VDS requires exclusive access, so we must not hold a handle.
    vds.clean(drive_index)
    
    -- 4. Re-open for Partitioning
    -- Give VDS a moment to settle
    kernel32.Sleep(500)
    
    drive = physical.open(drive_index, true, true)
    if not drive then return false, "Re-open failed" end
    if not drive:lock(true) then drive:close(); return false, "Re-lock failed" end
    
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok, err = layout.apply_partition_plan(drive, scheme, plan)
    
    drive:close()
    
    -- 5. Wait for Windows to mount new volumes
    kernel32.Sleep(1000)
    
    return ok, err or plan
end

function M.clean_all(drive_index, cb)
    volume.unmount_all_on_disk(drive_index)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    local ok = drive:zero_fill(cb)
    drive:close()
    return ok
end

function M.check_health(drive_index, cb, write_test)
    if write_test then volume.unmount_all_on_disk(drive_index) end
    local drive = physical.open(drive_index, write_test, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    
    -- [Passed] Correct patterns for write test
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg, stats = badblocks.check(drive, cb, false, patterns)
    
    drive:close()
    return ok, stats
end

function M.format_partition(drive_idx, offset, fs, label, opts)
    opts = opts or {}
    -- Verify partition exists
    local drive = physical.open(drive_idx)
    if not drive then return false end
    local info = layout.get_info(drive)
    drive:close()
    
    local p_size = 0
    local p_num = -1
    for _, p in ipairs(info and info.partitions or {}) do
        if p.offset == offset then p_size = p.length; p_num = p.number; break end
    end
    if p_num == -1 then return false, "Partition not found" end
    
    -- Strategy 1: Enhanced FAT32 (Lua implementation)
    if fs:upper() == "FAT32" and p_size > 32*1024*1024*1024 then
        local pd = physical.open(drive_idx, true, true)
        if pd and pd:lock(true) then
            local ok = fat32_lib.format(pd, offset, p_size, label)
            pd:close()
            if ok then return true, "Lua FAT32" end
        end
    end
    
    -- Strategy 2: VDS (Modern System API)
    local ok, msg = vds.format(drive_idx, offset, fs, label, true, 0, 0)
    if ok then return true, "VDS" end
    
    -- Strategy 3: Legacy (Mount + FMIFS)
    local ok_mount, letter = volume.assign(drive_idx, offset)
    if ok_mount then
        local drive_letter = letter:sub(1,1)
        if format_lib.format(drive_letter, fs, label, true) then
            if opts.compress and fs:upper()=="NTFS" then format_lib.enable_compression(drive_letter) end
            volume.remove_mount_point(letter)
            return true, "Legacy"
        end
        volume.remove_mount_point(letter)
    end
    
    return false, "All methods failed"
end

function M.create_partition(drive_index, offset, size, params)
    return vds.create_partition(drive_index, offset, size, params)
end

function M.set_active(drive_index, part_idx)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    local ok, err = layout.set_active(drive, part_idx, true)
    drive:close()
    return ok, err
end

function M.set_partition_type(drive_index, part_idx, type_id)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    local ok, err = layout.set_partition_type(drive, part_idx, type_id)
    drive:close()
    return ok, err
end

function M.set_partition_attributes(drive_index, part_idx, attrs)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    local ok, err = layout.set_partition_attributes(drive, part_idx, attrs)
    drive:close()
    return ok, err
end

function M.set_label(path, label)
    return volume.set_label(path, label)
end

function M.rescan()
    local ctx = vds.create_context()
    if ctx then
        ctx.service.lpVtbl.Refresh(ctx.service)
        ctx.service.lpVtbl.Reenumerate(ctx.service)
        ctx:close()
        return true
    end
    return false
end

function M.repair_filesystem(drive, fs)
    return format_lib.check_disk(drive, fs, true)
end

function M.revive_device(idx)
    if device.cycle_port(idx) then kernel32.Sleep(2000); return true end
    return device.cycle_disk(idx)
end

return M