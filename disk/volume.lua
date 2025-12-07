local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.core.handle'
local C = require 'win-utils.core.ffi_defs'
local table_new = require 'table.new'
local table_ext = require 'ext.table'

-- [RESTORED] Shrink IOCTL Structure
ffi.cdef[[
    typedef struct _SHRINK_VOLUME_INFORMATION {
        int ShrinkRequestType; // 1=Prepare, 2=Commit, 3=Abort
        long long Flags;
        long long NewSize;
    } SHRINK_VOLUME_INFORMATION;
]]

local M = {}

local DRIVE_TYPES = {
    [0] = "Unknown",
    [1] = "No Root",
    [2] = "Removable",
    [3] = "Fixed",
    [4] = "Remote",
    [5] = "CDROM",
    [6] = "RAMDisk"
}

function M.get_type(root)
    local path = root
    if path and not path:match("[\\/]$") then 
        path = path .. "\\" 
    end
    local t = kernel32.GetDriveTypeW(util.to_wide(path))
    return DRIVE_TYPES[t] or "Unknown"
end

function M.list_letters()
    local mask = kernel32.GetLogicalDrives()
    local list = {}
    for i = 0, 25 do
        if bit.band(mask, bit.lshift(1, i)) ~= 0 then
            table.insert(list, string.char(65 + i) .. ":")
        end
    end
    return list
end

function M.list()
    local name = ffi.new("wchar_t[261]")
    local hFind = kernel32.FindFirstVolumeW(name, 261)
    if hFind == ffi.cast("HANDLE", -1) then return nil, util.last_error("FindFirstVolume") end
    
    local res = table_new(8, 0)
    setmetatable(res, { __index = table_ext })
    
    ::continue_enum::
    
    local item = { 
        guid_path = util.from_wide(name), 
        mount_points = {} 
    }
    
    local buf = ffi.new("wchar_t[1024]")
    local len = ffi.new("DWORD[1]")
    
    if kernel32.GetVolumePathNamesForVolumeNameW(name, buf, 1024, len) ~= 0 then
        local p = buf
        while true do
            local mp = util.from_wide(p)
            if not mp or mp == "" then break end
            table.insert(item.mount_points, mp)
            while p[0] ~= 0 do p = p + 1 end
            p = p + 1
            if p >= buf + len[0] then break end
        end
    end
    
    local lab = ffi.new("wchar_t[261]")
    local fs = ffi.new("wchar_t[261]")
    if kernel32.GetVolumeInformationW(name, lab, 261, nil, nil, nil, fs, 261) ~= 0 then
        item.label = util.from_wide(lab)
        item.fs = util.from_wide(fs)
    end
    
    item.type = M.get_type(item.guid_path)
    table.insert(res, item)
    
    if kernel32.FindNextVolumeW(hFind, name, 261) ~= 0 then
        goto continue_enum
    end
    
    kernel32.FindVolumeClose(hFind)
    return res
end

function M.open(path, write)
    local p = path
    if p:match("^%a:$") then p = "\\\\.\\" .. p
    elseif p:match("^%a:\\$") then p = "\\\\.\\" .. p:sub(1,2) 
    elseif p:sub(-1)=="\\" then p = p:sub(1,-2) end
    
    local acc = write and bit.bor(C.GENERIC_READ, C.GENERIC_WRITE) or C.GENERIC_READ
    local h = kernel32.CreateFileW(util.to_wide(p), acc, 3, nil, 3, 0, nil)
    
    if h == ffi.cast("HANDLE", -1) then 
        return nil, util.last_error("CreateFile failed") 
    end
    return Handle(h)
end

function M.find_guid_by_partition(drive_index, partition_offset)
    local vols = M.list()
    if not vols then return nil end
    
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 then
                if ext.Extents[0].DiskNumber == drive_index and 
                   tonumber(ext.Extents[0].StartingOffset.QuadPart) == partition_offset then
                    hVol:close()
                    return v.guid_path
                end
            end
            hVol:close()
        end
    end
    return nil
end

function M.find_free_letter()
    local mask = kernel32.GetLogicalDrives()
    for i = 25, 2, -1 do 
        if bit.band(mask, bit.lshift(1, i)) == 0 then 
            return string.char(65 + i) .. ":\\" 
        end
    end
    return nil
end

function M.assign(idx, offset, letter)
    local guid_path = M.find_guid_by_partition(idx, offset)
    if not guid_path then return false, "Volume not found" end
    
    local mount_point = letter or M.find_free_letter()
    if not mount_point then return false, "No free letters" end
    
    if #mount_point == 2 then mount_point = mount_point .. "\\" end
    
    if kernel32.SetVolumeMountPointW(util.to_wide(mount_point), util.to_wide(guid_path)) == 0 then
        return false, util.last_error("SetVolumeMountPoint failed")
    end
    return true, mount_point
end

function M.unmount_all_on_disk(idx)
    local vols = M.list()
    if not vols then return end
    
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == idx then
                for _, mp in ipairs(v.mount_points) do 
                    kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) 
                end
                util.ioctl(hVol:get(), defs.IOCTL.DISMOUNT)
            end
            hVol:close()
        end
    end
end

-- [RESTORED] Remove a specific mount point (e.g. "X:\")
function M.remove_mount_point(path)
    local root = path
    if #root == 2 and root:sub(2,2) == ":" then root = root .. "\\" end
    
    if kernel32.DeleteVolumeMountPointW(util.to_wide(root)) == 0 then
        return false, util.last_error("DeleteVolumeMountPoint failed")
    end
    return true
end

function M.set_label(path, label)
    local root = path
    if #root == 2 and root:sub(2,2) == ":" then root = root .. "\\"
    elseif root:sub(-1) ~= "\\" then root = root .. "\\" end
    
    if kernel32.SetVolumeLabelW(util.to_wide(root), util.to_wide(label)) == 0 then
        return false, util.last_error("SetVolumeLabel failed")
    end
    return true
end

-- [RESTORED] Extend Volume to fill partition
-- This requires the underlying partition to be larger than the volume first (resize via layout.lua)
function M.extend(path)
    local h = M.open(path, true) -- Need Write Access
    if not h then return false, "Open failed" end
    
    local input = ffi.new("int64_t[1]", 0) -- 0 = Extend to max available
    local ok, err = util.ioctl(h:get(), defs.IOCTL.EXTEND, input, 8)
    
    h:close()
    return ok, err
end

-- [RESTORED] Shrink Volume (NTFS only)
-- @param size_mb: Size to remove in MB
function M.shrink(path, size_mb)
    local h = M.open(path, true)
    if not h then return false, "Open failed" end
    
    -- 1. Get Current Size
    local geo = util.ioctl(h:get(), defs.IOCTL.GET_GEO, nil, 0, "DISK_GEOMETRY_EX")
    if not geo then h:close(); return false, "GetGeometry failed" end
    
    local current_bytes = tonumber(geo.DiskSize.QuadPart)
    local shrink_bytes = size_mb * 1024 * 1024
    local target_bytes = current_bytes - shrink_bytes
    
    if target_bytes < 0 then h:close(); return false, "Target size negative" end
    
    -- 2. Call Shrink IOCTL
    local info = ffi.new("SHRINK_VOLUME_INFORMATION")
    info.ShrinkRequestType = 2 -- Commit
    info.NewSize = target_bytes
    
    local ok, err = util.ioctl(h:get(), defs.IOCTL.SHRINK, info)
    
    h:close()
    return ok, err
end

return M