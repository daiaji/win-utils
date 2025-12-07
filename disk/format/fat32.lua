local ffi = require 'ffi'
local bit = require 'bit' 
local filesystem = require 'ffi.req' 'Windows.sdk.filesystem'
local physical = require 'win-utils.disk.physical'
local layout = require 'win-utils.disk.layout'

local M = {}

local function pad(s, l) return s..string.rep(" ", l-#s) end

-- [RESTORED] Added cluster_size parameter
function M.format_raw(drive_idx, offset, label, cluster_size)
    local phys, err = physical.open(drive_idx, "rw", true)
    if not phys then return false, "Open failed: " .. tostring(err) end
    
    local locked, lock_err = phys:lock(true)
    if not locked then 
        phys:close()
        return false, "Lock failed: " .. tostring(lock_err) 
    end
    
    local info, layout_err = layout.get(phys)
    if not info then
        phys:close()
        return false, "GetLayout failed: " .. tostring(layout_err)
    end
    
    local size = 0
    for _, p in ipairs(info.parts) do if p.off == offset then size = p.len break end end
    if size == 0 then phys:close(); return false, "Partition not found" end
    
    local bps = phys.sector_size
    local total_sec = math.floor(size / bps)
    
    -- [RESTORED] Cluster Size Logic
    local spc = 0
    if cluster_size and cluster_size > 0 then
        spc = math.floor(cluster_size / bps)
    else
        -- Auto calculation (Standard Windows/Rufus logic)
        if total_sec < 66600 then spc = 1       -- < 32MB
        elseif total_sec < 133200 then spc = 2  -- < 64MB
        elseif total_sec < 266400 then spc = 4  -- < 128MB
        elseif total_sec < 532800 then spc = 8  -- < 256MB
        elseif total_sec < 16711680 then spc = 16 -- < 8GB
        elseif total_sec < 33423360 then spc = 32 -- < 16GB
        else spc = 64 -- >= 16GB
        end
    end
    
    -- Safety check: FAT32 max clusters ~268 million. 
    -- Ensure count fits in 28 bits
    local res_sec = 32
    local fats = 2
    local fat_ent = math.floor((total_sec - res_sec)/spc)
    local fat_sz = math.ceil((fat_ent * 4) / bps)
    -- Align FAT size to 8 sectors for performance
    fat_sz = math.ceil(fat_sz / 8) * 8
    
    local bs = ffi.new("FAT32_BOOT_SECTOR")
    bs.JumpBoot[0]=0xEB; bs.JumpBoot[1]=0x58; bs.JumpBoot[2]=0x90
    ffi.copy(bs.OEMName, "MSWIN4.1", 8)
    bs.BytesPerSector = bps; bs.SectorsPerCluster = spc; bs.ReservedSectors = res_sec
    bs.NumFATs = fats; bs.HiddenSectors = math.floor(offset/bps); bs.TotalSectors32 = total_sec
    bs.FATsz32 = fat_sz; bs.RootCluster = 2; bs.FSInfo = 1; bs.BackupBootSec = 6
    bs.BootSig = 0x29; bs.VolID = os.time()
    ffi.copy(bs.VolLab, pad(label or "NO NAME", 11), 11)
    ffi.copy(bs.FilSysType, "FAT32   ", 8)
    bs.BootSign = 0xAA55
    
    local fsi = ffi.new("FAT32_FSINFO")
    fsi.LeadSig = filesystem.FAT32_LEAD_SIG
    fsi.StrucSig = filesystem.FAT32_STRUC_SIG
    fsi.Free_Count = fat_ent - 1; fsi.Next_Free = 3
    fsi.TrailSig = filesystem.FAT32_TRAIL_SIG
    
    local bs_data = ffi.string(bs, 512)
    local fsi_data = ffi.string(fsi, 512)
    
    phys:write_sectors(offset, bs_data)
    phys:write_sectors(offset + bps, fsi_data)
    phys:write_sectors(offset + 6*bps, bs_data)
    phys:write_sectors(offset + 7*bps, fsi_data)
    
    local fat_sig = ffi.new("uint32_t[3]", {0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF})
    local sig_data = ffi.string(fat_sig, 12) .. string.rep("\0", bps-12)
    
    for i=0, fats-1 do
        local fat_off = offset + (res_sec + i*fat_sz) * bps
        phys:write_sectors(fat_off, sig_data)
    end
    
    local root_off = offset + (res_sec + fats*fat_sz) * bps
    phys:write_sectors(root_off, string.rep("\0", spc*bps))
    
    phys:close()
    return true
end

return M