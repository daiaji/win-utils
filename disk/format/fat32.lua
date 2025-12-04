local ffi = require 'ffi'
local M = {}

ffi.cdef[[
    #pragma pack(1)
    typedef struct {
        uint8_t Jmp[3]; uint8_t OEM[8]; uint16_t BytesPerSec; uint8_t SecPerClus;
        uint16_t RsvdSecCnt; uint8_t NumFATs; uint16_t RootEntCnt; uint16_t TotSec16;
        uint8_t Media; uint16_t FATSz16; uint16_t SecPerTrk; uint16_t NumHeads;
        uint32_t HiddSec; uint32_t TotSec32; uint32_t FATSz32; uint16_t ExtFlags;
        uint16_t FSVer; uint32_t RootClus; uint16_t FSInfo; uint16_t BkBootSec;
        uint8_t Rsvd[12]; uint8_t DrvNum; uint8_t Res1; uint8_t BootSig;
        uint32_t VolID; uint8_t VolLab[11]; uint8_t FilSysType[8]; uint8_t BootCode[420]; uint16_t BootSign;
    } FAT32_BS;
    typedef struct {
        uint32_t LeadSig; uint8_t Res1[480]; uint32_t StrucSig; uint32_t Free_Count;
        uint32_t Next_Free; uint8_t Res2[12]; uint32_t TrailSig;
    } FAT32_FSINFO;
    #pragma pack()
]]

local function pad(s, l) return s..string.rep(" ", l-#s) end

function M.format_volume(letter, label)
    -- This assumes 'letter' is a mounted drive letter or path like "E:"
    -- To format a physical partition, we need the PhysicalDrive object and offset
    return false, "Use format_raw for PhysicalDrive"
end

function M.format_raw(drive_idx, offset, label)
    local phys = require('win-utils.disk.physical').open(drive_idx, "rw", true)
    if not phys then return false, "Open failed" end
    if not phys:lock(true) then phys:close(); return false, "Lock failed" end
    
    -- Get partition size from layout
    local layout = require('win-utils.disk.layout').get(phys)
    local size = 0
    for _, p in ipairs(layout.parts) do if p.off == offset then size = p.len break end end
    if size == 0 then phys:close(); return false, "Partition not found" end
    
    local bps = phys.sector_size
    local total_sec = math.floor(size / bps)
    local spc = 8 -- Default 4KB cluster
    if total_sec > 66600 then spc = 8 end -- Simplified logic
    
    local res_sec = 32
    local fats = 2
    local fat_ent = math.floor((total_sec - res_sec)/spc)
    local fat_sz = math.ceil((fat_ent * 4) / bps)
    
    -- Boot Sector
    local bs = ffi.new("FAT32_BS")
    bs.Jmp[0]=0xEB; bs.Jmp[1]=0x58; bs.Jmp[2]=0x90
    ffi.copy(bs.OEMName, "MSWIN4.1", 8)
    bs.BytesPerSec = bps; bs.SecPerClus = spc; bs.RsvdSecCnt = res_sec
    bs.NumFATs = fats; bs.HiddSec = math.floor(offset/bps); bs.TotSec32 = total_sec
    bs.FATSz32 = fat_sz; bs.RootClus = 2; bs.FSInfo = 1; bs.BkBootSec = 6
    bs.BootSig = 0x29; bs.VolID = os.time()
    ffi.copy(bs.VolLab, pad(label or "NO NAME", 11), 11)
    ffi.copy(bs.FilSysType, "FAT32   ", 8)
    bs.BootSign = 0xAA55
    
    -- FSInfo
    local fsi = ffi.new("FAT32_FSINFO")
    fsi.LeadSig = 0x41615252; fsi.StrucSig = 0x61417272
    fsi.Free_Count = fat_ent - 1; fsi.Next_Free = 3; fsi.TrailSig = 0xAA550000
    
    -- Write
    local bs_data = ffi.string(bs, 512)
    local fsi_data = ffi.string(fsi, 512)
    
    phys:write_sectors(offset, bs_data)
    phys:write_sectors(offset + bps, fsi_data)
    phys:write_sectors(offset + 6*bps, bs_data)
    phys:write_sectors(offset + 7*bps, fsi_data)
    
    -- Init FAT
    local fat_sig = ffi.new("uint32_t[3]", {0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF})
    local sig_data = ffi.string(fat_sig, 12) .. string.rep("\0", bps-12)
    
    for i=0, fats-1 do
        local fat_off = offset + (res_sec + i*fat_sz) * bps
        phys:write_sectors(fat_off, sig_data)
        -- Wipe rest of 1st sector of FAT? Already done by padding above
    end
    
    -- Wipe Root Dir
    local root_off = offset + (res_sec + fats*fat_sz) * bps
    phys:write_sectors(root_off, string.rep("\0", spc*bps))
    
    phys:close()
    return true
end

return M