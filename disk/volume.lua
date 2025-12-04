local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 辅助：解析 DOS 目标
local function resolve_dos_target(dos_path)
    local buf = ffi.new("wchar_t[1024]")
    local clean_path = dos_path:gsub("\\$", "")
    if kernel32.QueryDosDeviceW(util.to_wide(clean_path), buf, 1024) == 0 then return nil end
    return util.from_wide(buf)
end

function M.list()
    local name = ffi.new("wchar_t[261]")
    local hFind = kernel32.FindFirstVolumeW(name, 261)
    if hFind == ffi.cast("HANDLE", -1) then return nil end
    
    local res = {}
    repeat
        local guid = util.from_wide(name)
        local item = { guid_path = guid, mount_points = {} }
        
        local buf = ffi.new("wchar_t[1024]"); local len = ffi.new("DWORD[1]")
        if kernel32.GetVolumePathNamesForVolumeNameW(name, buf, 1024, len) ~= 0 then
            local p = buf
            while true do
                local mp = util.from_wide(p)
                if not mp or mp == "" then break end
                table.insert(item.mount_points, mp)
                while p[0] ~= 0 do p = p + 1 end; p = p + 1
                if p >= buf + len[0] then break end
            end
        end
        
        local lab = ffi.new("wchar_t[261]"); local fs = ffi.new("wchar_t[261]")
        if kernel32.GetVolumeInformationW(name, lab, 261, nil, nil, nil, fs, 261) ~= 0 then
            item.label = util.from_wide(lab)
            item.fs = util.from_wide(fs)
        end
        table.insert(res, item)
    until kernel32.FindNextVolumeW(hFind, name, 261) == 0
    kernel32.FindVolumeClose(hFind)
    return res
end

function M.get_info(path)
    if not path then return nil, "Invalid path" end
    local root = path
    if root:match("^%a:$") then root = root .. "\\" end
    if root:sub(-1) ~= "\\" then root = root .. "\\" end
    
    local wroot = util.to_wide(root)
    local label = ffi.new("wchar_t[261]")
    local fs = ffi.new("wchar_t[261]")
    local serial = ffi.new("DWORD[1]")
    
    if kernel32.GetVolumeInformationW(wroot, label, 261, serial, nil, nil, fs, 261) == 0 then
        return nil, util.format_error()
    end
    
    local type_id = kernel32.GetDriveTypeW(wroot)
    local type_map = {[2]="Removable", [3]="Fixed", [4]="Remote", [5]="CDROM", [6]="RAMDisk"}
    
    local free = ffi.new("ULARGE_INTEGER")
    local total = ffi.new("ULARGE_INTEGER")
    kernel32.GetDiskFreeSpaceExW(wroot, free, total, nil)
    
    return {
        label = util.from_wide(label),
        filesystem = util.from_wide(fs),
        serial = serial[0],
        type = type_map[type_id] or "Unknown",
        capacity_bytes = tonumber(total.QuadPart),
        free_bytes = tonumber(free.QuadPart),
        capacity_mb = tonumber(total.QuadPart) / 1048576,
        free_mb = tonumber(free.QuadPart) / 1048576
    }
end

function M.get_space(path)
    if not path then return nil, "Invalid path" end
    if path:match("^%a:$") then path = path .. "\\" end
    
    local wpath = util.to_wide(path)
    local free_avail = ffi.new("ULARGE_INTEGER")
    local total = ffi.new("ULARGE_INTEGER")
    
    if kernel32.GetDiskFreeSpaceExW(wpath, free_avail, total, nil) == 0 then
        return nil, util.format_error()
    end
    
    return {
        free_bytes = tonumber(free_avail.QuadPart),
        total_bytes = tonumber(total.QuadPart),
        free_mb = tonumber(free_avail.QuadPart) / 1048576,
        total_mb = tonumber(total.QuadPart) / 1048576
    }
end

function M.open(path, write)
    local p = path
    if p:match("^%a:$") then p = "\\\\.\\" .. p
    elseif p:match("^%a:\\$") then p = "\\\\.\\" .. p:sub(1,2) 
    elseif p:sub(-1)=="\\" then p = p:sub(1,-2) end
    
    local acc = write and bit.bor(C.GENERIC_READ, C.GENERIC_WRITE) or C.GENERIC_READ
    local h = kernel32.CreateFileW(util.to_wide(p), acc, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return nil, util.format_error() end
    -- [FIX] Handle(h)
    return Handle(h)
end

function M.extend(vol_handle, size_mb)
    local input = ffi.new("LARGE_INTEGER")
    input.QuadPart = 0 -- 0 means extend to fill available space
    local raw_handle = vol_handle.get and vol_handle:get() or vol_handle
    local res = util.ioctl(raw_handle, defs.IOCTL.FSCTL_EXTEND_VOLUME, input, ffi.sizeof(input))
    return res ~= nil
end

function M.shrink(vol_handle, size_mb)
    if not size_mb or size_mb <= 0 then return false, "Invalid size" end
    local raw_handle = vol_handle.get and vol_handle:get() or vol_handle
    
    local geo = util.ioctl(raw_handle, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, nil, 0, "DISK_GEOMETRY_EX")
    if not geo then return false, "GetGeometry failed" end
    
    local current = tonumber(geo.DiskSize.QuadPart)
    local target = current - (size_mb * 1048576)
    if target < 0 then return false, "Target negative" end
    
    local shrink = ffi.new("SHRINK_VOLUME_INFORMATION")
    shrink.ShrinkRequestType = 2 -- Commit
    shrink.Flags = 0
    shrink.NewSize = target
    
    local res = util.ioctl(raw_handle, defs.IOCTL.FSCTL_SHRINK_VOLUME, shrink, ffi.sizeof(shrink))
    return res ~= nil
end

function M.unmount_all_on_disk(idx)
    local vols = M.list()
    if not vols then return end
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == idx then
                for _, mp in ipairs(v.mount_points) do kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) end
                util.ioctl(hVol:get(), defs.IOCTL.FSCTL_DISMOUNT_VOLUME)
            end
            hVol:close()
        end
    end
end

function M.find_guid_by_partition(drive_index, partition_offset)
    local vols = M.list()
    if not vols then return nil end
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
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
    
    -- Fallback for unmounted partitions
    local layout_mod = require 'win-utils.disk.layout'
    local phys_mod = require 'win-utils.disk.physical'
    local drive = phys_mod.open(drive_index)
    if not drive then return nil end
    local info = layout_mod.get_info(drive)
    drive:close()
    if not info then return nil end
    
    local p_num = -1
    for _, p in ipairs(info.partitions) do
        if p.offset == partition_offset then p_num = p.number; break end
    end
    
    if p_num > 0 then
        local alias = string.format("Harddisk%dPartition%d", drive_index, p_num)
        local target = resolve_dos_target(alias)
        if target then return "\\\\?\\GLOBALROOT" .. target .. "\\" end
    end
    return nil
end

function M.find_free_letter()
    local mask = kernel32.GetLogicalDrives()
    for i = 25, 2, -1 do
        if bit.band(mask, bit.lshift(1, i)) == 0 then return string.char(65 + i) .. ":\\" end
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
        return false, util.format_error()
    end
    return true, mount_point
end

function M.remove_mount_point(mp)
    if #mp == 2 then mp = mp .. "\\" end
    return kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) ~= 0
end

function M.set_label(path, label)
    local p = path
    if #p==2 then p=p.."\\" elseif p:sub(-1)~="\\" then p=p.."\\" end
    return kernel32.SetVolumeLabelW(util.to_wide(p), util.to_wide(label)) ~= 0
end

return M