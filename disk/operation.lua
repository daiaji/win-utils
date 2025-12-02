local ffi = require 'ffi'
local physical = require 'win-utils.disk.physical'
local layout = require 'win-utils.disk.layout'
local vds = require 'win-utils.disk.vds'
local format_lib = require 'win-utils.disk.format.fmifs'
local fat32_lib = require 'win-utils.disk.format.fat32'
local volume = require 'win-utils.disk.volume'
local mount = require 'win-utils.disk.mount'
local device = require 'win-utils.device'
local badblocks = require 'win-utils.disk.badblocks'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local types = require 'win-utils.disk.types'

local M = {}

-- Helper: Map FS name to MBR Type ID
local function get_mbr_type_for_fs(fs_name)
    local fs = fs_name:upper()
    if fs == "NTFS" or fs == "EXFAT" or fs == "UDF" or fs == "REFS" then
        return types.MBR.NTFS -- 0x07
    elseif fs == "FAT32" then
        return types.MBR.FAT32_LBA -- 0x0C (LBA is standard now)
    elseif fs == "FAT" or fs == "FAT16" then
        return types.MBR.FAT16_LBA -- 0x0E
    elseif fs:find("EXT") then
        return types.MBR.LINUX -- 0x83
    end
    return nil
end

-- High-level command to wipe and re-partition a drive
function M.prepare_drive(drive_index, scheme, opts)
    -- [NEW] Robustness: Unmount all logical volumes first
    -- This prevents "Access Denied" when trying to lock the physical drive
    volume.unmount_all_on_disk(drive_index)

    local drive = physical.open(drive_index, true, true) -- Exclusive write
    if not drive then return false, "Could not open drive" end

    -- 1. Lock (Force kill processes)
    if not drive:lock(true) then 
        drive:close()
        return false, "Could not lock drive" 
    end

    -- 2. Wipe MBR/GPT headers
    drive:wipe_layout()

    -- 3. VDS Clean (if available, for robustness)
    vds.clean(drive_index)

    -- 4. Create Partition Layout
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok, err = layout.apply_partition_plan(drive, scheme, plan)
    
    if not ok then
        drive:close()
        return false, err
    end

    -- 5. Refresh & Wait
    drive:close() -- Release lock to allow Windows to see new partitions
    
    kernel32.Sleep(1000)

    return true, plan
end

-- Clean All (Zero Fill)
function M.clean_all(drive_index, progress_cb)
    -- [NEW] Robustness: Unmount all
    volume.unmount_all_on_disk(drive_index)

    local drive = physical.open(drive_index, true, true)
    if not drive then return false, "Could not open drive" end
    
    if not drive:lock(true) then
        drive:close()
        return false, "Could not lock drive"
    end
    
    local ok, err = drive:zero_fill(progress_cb)
    
    drive:close()
    return ok, err
end

-- Bad Block Scan
-- @param write_test: If true, performs destructive write-verify test
function M.check_health(drive_index, progress_cb, write_test, patterns)
    if write_test then
        -- [NEW] Robustness: Unmount all if writing
        volume.unmount_all_on_disk(drive_index)
    end

    local drive = physical.open(drive_index, write_test, true) 
    if not drive then return false, "Could not open drive" end
    
    if not drive:lock(true) then
        drive:close()
        return false, "Could not lock drive"
    end
    
    local ok, err, report = badblocks.check(drive, progress_cb, false, patterns)
    
    drive:close()
    return ok, err, report
end

-- Create Single Partition (Add to existing)
function M.create_partition(drive_index, offset, size, params)
    return vds.create_partition(drive_index, offset, size, params)
end

-- Set Active Partition
function M.set_active(drive_index, partition_idx)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false, "Could not open drive" end
    
    if not drive:lock(true) then
        drive:close()
        return false, "Could not lock drive"
    end
    
    local ok, err = layout.set_active(drive, partition_idx, true)
    
    drive:close()
    return ok, err
end

-- Change Label
function M.set_label(path, label)
    return volume.set_label(path, label)
end

-- Change Partition Type (ID)
function M.set_partition_type(drive_index, part_idx, type_id)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false, "Could not open drive" end
    
    if not drive:lock(true) then
        drive:close()
        return false, "Could not lock drive"
    end
    
    local ok, err = layout.set_partition_type(drive, part_idx, type_id)
    
    drive:close()
    return ok, err
end

-- Set Partition Attributes (GPT Only)
function M.set_partition_attributes(drive_index, part_idx, attrs)
    local drive = physical.open(drive_index, true, true)
    if not drive then return false, "Could not open drive" end
    
    if not drive:lock(true) then
        drive:close()
        return false, "Could not lock drive"
    end
    
    local ok, err = layout.set_partition_attributes(drive, part_idx, attrs)
    
    drive:close()
    return ok, err
end

-- Rescan Disks
function M.rescan()
    local ctx, err = vds.create_context()
    if ctx then
        ctx.service.lpVtbl.Refresh(ctx.service)
        ctx.service.lpVtbl.Reenumerate(ctx.service)
        ctx:close()
        return true
    end
    return false, err
end

-- Repair Filesystem
function M.repair_filesystem(drive_letter, fs_name)
    return format_lib.check_disk(drive_letter, fs_name, true)
end

-- Smart Format
-- @param options: { compress = boolean }
function M.format_partition(drive_index, offset, fs, label, options)
    options = options or {}
    local size_limit_32gb = 32 * 1024 * 1024 * 1024
    
    -- Get partition info
    local drive = physical.open(drive_index)
    local part_size = 0
    local part_index = -1
    local part_style = "UNKNOWN"
    
    if drive then
        local info = layout.get_info(drive)
        drive:close()
        if info then
            part_style = info.style
            for _, p in ipairs(info.partitions) do
                if p.offset == offset then 
                    part_size = p.length
                    part_index = p.number
                    break 
                end
            end
        end
    end

    if part_index == -1 then return false, "Partition not found" end

    local format_ok = false
    local format_method = ""

    -- 1. Enhanced Lua FAT32 for Large drives
    if (fs:upper() == "FAT32") and (part_size > size_limit_32gb) then
        local pDrive = physical.open(drive_index, true, true)
        if pDrive then
            if pDrive:lock(true) then
                local ok, err = fat32_lib.format(pDrive, offset, part_size, label)
                pDrive:close()
                if ok then 
                    format_ok = true
                    format_method = "Enhanced Lua FAT32"
                end
            else
                pDrive:close()
            end
        end
    end

    -- [FIX] Format Retries (Robustness)
    -- Matches Rufus logic (WRITE_RETRIES loop) to handle transient locks/errors
    local retries = 4
    local retry_delay = 3000 -- 3 seconds

    -- 2. Try VDS
    if not format_ok then
        local use_vds = true
        if options.compress and fs:upper() == "NTFS" then use_vds = false end -- Fallback to legacy for compression
        
        if use_vds then
            for i = 1, retries do
                local ok, msg = vds.format(drive_index, offset, fs, label, true)
                if ok then 
                    format_ok = true
                    format_method = "VDS: " .. msg
                    break
                else
                    if i < retries then kernel32.Sleep(retry_delay) end
                end
            end
        end
    end

    -- 3. Fallback: Mount and use fmifs
    if not format_ok then
        local letter, err = volume.assign(drive_index, offset)
        if letter then 
            local drive_letter = letter:sub(1,1)
            
            for i = 1, retries do
                if format_lib.format(drive_letter, fs, label, true) then
                    format_ok = true
                    format_method = "Legacy (fmifs)"
                    
                    if options.compress and fs:upper() == "NTFS" then
                        format_lib.enable_compression(drive_letter)
                    end
                    break
                else
                    if i < retries then kernel32.Sleep(retry_delay) end
                end
            end
            
            volume.remove_mount_point(letter)
        end
    end

    if not format_ok then return false, "All format methods failed" end

    -- Update Partition Type ID if MBR
    if part_style == "MBR" then
        local target_type = get_mbr_type_for_fs(fs)
        if target_type then
            local pDrive = physical.open(drive_index, true, true)
            if pDrive then
                if pDrive:lock(false) then -- Try non-force lock first
                    layout.set_partition_type(pDrive, part_index, target_type)
                end
                pDrive:close()
            end
        end
    end

    return true, format_method
end

function M.revive_device(drive_index)
    local ok, err = device.cycle_port(drive_index)
    if ok then kernel32.Sleep(2000); return true, "Hardware Port Reset" end
    ok, err = device.cycle_disk(drive_index)
    if ok then return true, "Software Device Cycle" end
    return false, err
end

return M