local M = {}

function M.format(idx, off, fs, lab, opts)
    opts = opts or {}
    local mount = require 'win-utils.disk.mount'
    local fat32 = require 'win-utils.disk.format.fat32'
    local fmifs = require 'win-utils.disk.format.fmifs'
    local physical = require 'win-utils.disk.physical'
    local layout = require 'win-utils.disk.layout'
    local ntfs = require 'win-utils.fs.ntfs'
    local volume = require 'win-utils.disk.volume'
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

    -- 1. Identify partition size
    local drive, err = physical.open(idx, "r")
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local media_type = drive.media_type
    local info, l_err = layout.get(drive)
    drive:close()
    
    if not info then return false, "GetLayout failed: " .. tostring(l_err) end
    
    local p_size = 0
    for _, p in ipairs(info.parts) do
        if p.off == off then p_size = p.len; break end
    end
    if p_size == 0 then return false, "Partition not found at offset " .. off end

    local fs_lower = fs:lower()
    local cluster = opts.cluster_size

    -- [Strategy 1] Enhanced Lua FAT32 (For >32GB partitions where Windows limits FAT32)
    if fs_lower == "fat32" and p_size > 32*1024*1024*1024 then
        local ok, f_err = fat32.format_raw(idx, off, lab, cluster)
        if ok then return true, "Lua FAT32" end
    end
    
    -- [Strategy 2] Legacy FMIFS (Standard Windows Format)
    local target_path = nil
    local is_temp_mount = false
    
    -- Polling for volume arrival (needed after partitioning)
    for i=1, 40 do
        target_path = volume.find_guid_by_partition(idx, off)
        if target_path then break end
        kernel32.Sleep(250)
    end
    
    -- If not mounted automatically, try temporary mount
    if not target_path then
        target_path = mount.temp_mount(idx, off)
        if target_path then is_temp_mount = true end
    end
    
    if target_path then
        local ok_fmifs, msg_fmifs = fmifs.format(target_path, fs, lab, media_type, cluster)
        
        if ok_fmifs and lab and lab ~= "" then
            volume.set_label(target_path, lab)
        end
        
        if ok_fmifs and opts.compress and fs_lower == "ntfs" then
            ntfs.set_compression(target_path, true)
        end
        
        if is_temp_mount then mount.unmount(target_path) end
        
        if ok_fmifs then 
            return true, "Legacy FMIFS"
        else
            return false, "FMIFS Failed: " .. tostring(msg_fmifs)
        end
    end
    
    return false, "Volume not mounted or accessible"
end

return M