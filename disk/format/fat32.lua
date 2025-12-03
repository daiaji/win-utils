local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
-- 假设 filesystem.lua 定义了 FAT32_BOOT_SECTOR 等结构体，如果未定义需在此定义
require 'ffi.req' 'Windows.sdk.filesystem' 

local M = {}
local C = ffi.C

-- 字符串填充辅助
local function pad(s, len)
    if #s > len then return s:sub(1, len) end
    return s .. string.rep(" ", len - #s)
end

-- 完整的 FAT32 格式化逻辑
-- @param drive: PhysicalDrive 实例 (必须已锁定)
function M.format(drive, offset, size, label, cluster_size)
    if not drive or not offset or not size then return false, "Invalid args" end

    local bps = drive.sector_size
    local total_sectors = math.floor(size / bps)
    
    -- 1. 计算簇大小 (参考 Rufus/MS 标准)
    local spc = 0 -- Sectors Per Cluster
    if cluster_size then
        spc = math.floor(cluster_size / bps)
    else
        if total_sectors < 66600 then spc = 1
        elseif total_sectors < 133200 then spc = 2
        elseif total_sectors < 266400 then spc = 4
        elseif total_sectors < 532800 then spc = 8
        elseif total_sectors < 16711680 then spc = 16
        elseif total_sectors < 33423360 then spc = 32
        else spc = 64 end
    end
    
    local res_sectors = 32
    local num_fats = 2
    local root_cluster = 2
    
    -- 计算 FAT 表大小
    -- FATsz = (TotalSec - ResSec) / ( (SecPerClus * 256) + NumFATs ) / 2
    local fat_entries = math.floor((total_sectors - res_sectors) / spc)
    local fat_bytes = fat_entries * 4
    local fat_sectors = math.ceil(fat_bytes / bps)
    fat_sectors = math.ceil(fat_sectors / 8) * 8 -- Align
    
    -- 2. 准备 Boot Sector
    local bs = ffi.new("FAT32_BOOT_SECTOR")
    bs.JumpBoot[0] = 0xEB; bs.JumpBoot[1] = 0x58; bs.JumpBoot[2] = 0x90
    ffi.copy(bs.OEMName, "MSWIN4.1", 8)
    bs.BytesPerSector = bps
    bs.SectorsPerCluster = spc
    bs.ReservedSectors = res_sectors
    bs.NumFATs = num_fats
    bs.HiddenSectors = math.floor(offset / bps)
    bs.TotalSectors32 = total_sectors
    bs.FATsz32 = fat_sectors
    bs.RootCluster = root_cluster
    bs.FSInfo = 1
    bs.BackupBootSec = 6
    bs.DriveNumber = 0x80
    bs.BootSig = 0x29
    bs.VolID = os.time()
    ffi.copy(bs.VolLab, pad(label or "NO NAME", 11), 11)
    ffi.copy(bs.FilSysType, "FAT32   ", 8)
    bs.BootSign = 0xAA55
    
    -- 3. 准备 FSInfo
    local fsi = ffi.new("FAT32_FSINFO")
    fsi.LeadSig = 0x41615252
    fsi.StrucSig = 0x61417272
    fsi.Free_Count = (total_sectors - res_sectors - (num_fats * fat_sectors)) / spc - 1
    fsi.Next_Free = 3
    fsi.TrailSig = 0xAA550000
    
    -- 4. 写入结构
    local bs_data = ffi.string(bs, 512)
    local fsi_data = ffi.string(fsi, 512)
    
    -- 主份
    if not drive:write_sectors(offset, bs_data) then return false, "Write BS failed" end
    if not drive:write_sectors(offset + 1 * bps, fsi_data) then return false, "Write FSInfo failed" end
    
    -- 备份
    if not drive:write_sectors(offset + 6 * bps, bs_data) then return false, "Write Backup BS failed" end
    if not drive:write_sectors(offset + 7 * bps, fsi_data) then return false, "Write Backup FSInfo failed" end
    
    -- 5. 初始化 FAT 表
    local fat_sig = ffi.new("uint32_t[3]")
    fat_sig[0] = 0x0FFFFFF8
    fat_sig[1] = 0x0FFFFFFF
    fat_sig[2] = 0x0FFFFFFF -- Root Dir EOC
    
    local sig_data = ffi.string(fat_sig, 12) .. string.rep("\0", bps - 12)
    local zero_buf = string.rep("\0", 1024 * 1024) -- 1MB wipe buffer
    
    for i = 0, num_fats - 1 do
        local fat_off = offset + (res_sectors + (i * fat_sectors)) * bps
        drive:write_sectors(fat_off, sig_data)
        
        -- 清除 FAT 表头部区域防止残留
        local curr = fat_off + bps
        local text_end = fat_off + math.min(fat_sectors * bps, 4 * 1024 * 1024) -- Wipe first 4MB of FAT
        while curr < text_end do
            local chunk = math.min(#zero_buf, text_end - curr)
            drive:write_sectors(curr, zero_buf:sub(1, chunk))
            curr = curr + chunk
        end
    end
    
    -- 6. 清除根目录
    local root_off = offset + (res_sectors + (num_fats * fat_sectors)) * bps
    drive:write_sectors(root_off, string.rep("\0", spc * bps))
    
    return true
end

return M