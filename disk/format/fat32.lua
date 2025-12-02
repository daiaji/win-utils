local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
local physical = require 'win-utils.disk.physical'
-- [NEW] Import structures
require 'ffi.req' 'Windows.sdk.filesystem'

local M = {}
local C = ffi.C

-- Helper to pad strings
local function pad_string(str, len)
    if #str > len then return str:sub(1, len) end
    return str .. string.rep(" ", len - #str)
end

-- Formats a partition as FAT32 (Large capacity support)
-- @param drive: Opened PhysicalDrive object (must be locked)
-- @param partition_offset: Start offset in bytes
-- @param partition_size: Size in bytes
-- @param label: Volume Label
-- @param cluster_size: Optional cluster size (default auto)
function M.format(drive, partition_offset, partition_size, label, cluster_size)
    if not drive or not partition_offset or not partition_size then 
        return false, "Invalid arguments" 
    end

    local bps = drive.sector_size
    local total_sectors = math.floor(partition_size / bps)
    
    -- 1. Determine Geometry
    local sec_per_cluster = 0
    if cluster_size then
        sec_per_cluster = math.floor(cluster_size / bps)
    else
        -- Auto calculation similar to Rufus/Microsoft
        if total_sectors < 66600 then sec_per_cluster = 1        -- < 32MB
        elseif total_sectors < 133200 then sec_per_cluster = 2   -- < 64MB
        elseif total_sectors < 266400 then sec_per_cluster = 4   -- < 128MB
        elseif total_sectors < 532800 then sec_per_cluster = 8   -- < 256MB
        elseif total_sectors < 16711680 then sec_per_cluster = 16 -- < 8GB
        elseif total_sectors < 33423360 then sec_per_cluster = 32 -- < 16GB
        else sec_per_cluster = 64 -- >= 16GB (32K clusters)
        end
    end
    
    local res_sectors = 32 -- Reserved sectors
    local num_fats = 2
    local root_cluster = 2
    
    -- Calculate FAT Size
    -- Formula: FATsz = (TotalSec - ResSec) / ( (SecPerClus * 256) + NumFATs ) / 2
    local fat_entries = math.floor((total_sectors - res_sectors) / sec_per_cluster)
    -- 4 bytes per entry
    local fat_sz_bytes = fat_entries * 4
    local fat_sz_sectors = math.ceil(fat_sz_bytes / bps)
    -- Align FAT size
    fat_sz_sectors = math.ceil(fat_sz_sectors / 8) * 8
    
    -- 2. Prepare Boot Sector
    local bs = ffi.new("FAT32_BOOT_SECTOR")
    bs.JumpBoot[0] = 0xEB; bs.JumpBoot[1] = 0x58; bs.JumpBoot[2] = 0x90
    ffi.copy(bs.OEMName, "MSWIN4.1", 8)
    bs.BytesPerSector = bps
    bs.SectorsPerCluster = sec_per_cluster
    bs.ReservedSectors = res_sectors
    bs.NumFATs = num_fats
    bs.RootEntryCount = 0 -- FAT32
    bs.TotalSectors16 = 0
    bs.Media = 0xF8
    bs.FATsz16 = 0
    bs.SectorsPerTrack = 63 -- Dummy
    bs.NumHeads = 255 -- Dummy
    bs.HiddenSectors = math.floor(partition_offset / bps)
    bs.TotalSectors32 = total_sectors
    bs.FATsz32 = fat_sz_sectors
    bs.ExtFlags = 0
    bs.FSVer = 0
    bs.RootCluster = root_cluster
    bs.FSInfo = 1
    bs.BackupBootSec = 6
    bs.DriveNumber = 0x80
    bs.BootSig = 0x29
    bs.VolID = os.time() -- Serial
    ffi.copy(bs.VolLab, pad_string(label or "NO NAME", 11), 11)
    ffi.copy(bs.FilSysType, "FAT32   ", 8)
    bs.BootSign = 0xAA55
    
    -- 3. Prepare FSInfo
    local fsi = ffi.new("FAT32_FSINFO")
    fsi.LeadSig = C.FAT32_LEAD_SIG
    fsi.StrucSig = C.FAT32_STRUC_SIG
    fsi.Free_Count = (total_sectors - res_sectors - (num_fats * fat_sz_sectors)) / sec_per_cluster - 1
    fsi.Next_Free = 3
    fsi.TrailSig = C.FAT32_TRAIL_SIG
    
    -- 4. Write Structures
    local bs_data = ffi.string(bs, 512)
    if not drive:write_sectors(partition_offset, bs_data) then return false, "Write BS failed" end
    
    local fsi_data = ffi.string(fsi, 512)
    if not drive:write_sectors(partition_offset + 1 * bps, fsi_data) then return false, "Write FSInfo failed" end
    
    -- Backup BS
    if not drive:write_sectors(partition_offset + 6 * bps, bs_data) then return false, "Write Backup BS failed" end
    
    -- Backup FSInfo
    if not drive:write_sectors(partition_offset + 7 * bps, fsi_data) then return false, "Write Backup FSInfo failed" end
    
    -- 5. Clear FATs and Initialize
    local fat_start_sig = ffi.new("uint32_t[3]")
    fat_start_sig[0] = 0x0FFFFF00 + 0xF8 -- 0x0FFFFFF8
    fat_start_sig[1] = 0x0FFFFFFF
    fat_start_sig[2] = 0x0FFFFFFF -- Root Dir EOC
    
    local sig_data = ffi.string(fat_start_sig, 12)
    local padding = string.rep("\0", bps - 12)
    local first_fat_sector = sig_data .. padding
    
    local zero_buf_size = 1024 * 1024 -- 1MB
    local zero_buf = string.rep("\0", zero_buf_size)
    
    for i = 0, num_fats - 1 do
        local fat_offset = partition_offset + (res_sectors + (i * fat_sz_sectors)) * bps
        
        -- Write Signature
        drive:write_sectors(fat_offset, first_fat_sector)
        
        -- Wipe FAT (Enhanced Robustness)
        local current_wipe_offset = fat_offset + bps
        local end_wipe_offset = fat_offset + (fat_sz_sectors * bps)
        
        while current_wipe_offset < end_wipe_offset do
            local chunk = math.min(zero_buf_size, end_wipe_offset - current_wipe_offset)
            if chunk == zero_buf_size then
                drive:write_sectors(current_wipe_offset, zero_buf)
            else
                drive:write_sectors(current_wipe_offset, string.rep("\0", chunk))
            end
            current_wipe_offset = current_wipe_offset + chunk
        end
    end
    
    -- 6. Clear Root Directory
    local root_offset = partition_offset + (res_sectors + (num_fats * fat_sz_sectors)) * bps
    drive:write_sectors(root_offset, string.rep("\0", sec_per_cluster * bps))
    
    return true
end

return M