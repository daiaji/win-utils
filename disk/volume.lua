local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- Resolve a DOS Device path
function M.resolve_dos_target(dos_path)
    local buf = ffi.new("wchar_t[1024]")
    local clean_path = dos_path:gsub("\\$", "")
    local res = kernel32.QueryDosDeviceW(util.to_wide(clean_path), buf, 1024)
    if res == 0 then return nil end
    return util.from_wide(buf)
end

function M.list()
    local volumes = {}
    local vol_name_buf = ffi.new("wchar_t[261]")
    local hFind = kernel32.FindFirstVolumeW(vol_name_buf, 261)
    
    if hFind == ffi.cast("HANDLE", -1) then return nil, util.format_error() end
    
    repeat
        local guid_path = util.from_wide(vol_name_buf)
        local vol_info = { guid_path = guid_path, mount_points = {} }
        
        local mp_buf_len = 1024
        local mp_buf = ffi.new("wchar_t[?]", mp_buf_len)
        local ret_len = ffi.new("DWORD[1]")
        
        if kernel32.GetVolumePathNamesForVolumeNameW(vol_name_buf, mp_buf, mp_buf_len, ret_len) ~= 0 then
            local ptr = mp_buf
            while true do
                local mp = util.from_wide(ptr)
                if not mp or mp == "" then break end
                table.insert(vol_info.mount_points, mp)
                local len = 0
                while ptr[len] ~= 0 do len = len + 1 end
                ptr = ptr + len + 1
                if ptr >= mp_buf + ret_len[0] then break end
            end
        end
        
        local label_buf = ffi.new("wchar_t[261]")
        local fs_buf = ffi.new("wchar_t[261]")
        if kernel32.GetVolumeInformationW(vol_name_buf, label_buf, 261, nil, nil, nil, fs_buf, 261) ~= 0 then
            vol_info.label = util.from_wide(label_buf)
            vol_info.fs = util.from_wide(fs_buf)
        end
        
        table.insert(volumes, vol_info)
        
    until kernel32.FindNextVolumeW(hFind, vol_name_buf, 261) == 0
    
    kernel32.FindVolumeClose(hFind)
    return volumes
end

function M.open(path)
    local vol_path = path
    if #path == 2 and path:sub(2,2) == ":" then
        vol_path = "\\\\.\\" .. path
    elseif path:sub(-1) == "\\" then
        vol_path = path:sub(1, -2) 
    end

    -- READ|WRITE access is usually required for FSCTL operations
    local h = kernel32.CreateFileW(util.to_wide(vol_path), 
        bit.bor(C.GENERIC_READ, C.GENERIC_WRITE), 
        bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), 
        nil, C.OPEN_EXISTING, 0, nil)
        
    if h == ffi.cast("HANDLE", -1) then return nil, util.format_error() end
    return Handle.guard(h)
end

-- [NEW] Internal helper to dismount a volume handle
local function force_dismount(hVol)
    local bytes = ffi.new("DWORD[1]")
    return kernel32.DeviceIoControl(hVol, defs.IOCTL.FSCTL_DISMOUNT_VOLUME, nil, 0, nil, 0, bytes, nil) ~= 0
end

function M.extend(vol_handle, size_mb)
    local input = ffi.new("LARGE_INTEGER")
    input.QuadPart = 0 
    local bytes = ffi.new("DWORD[1]")
    if kernel32.DeviceIoControl(vol_handle, defs.IOCTL.FSCTL_EXTEND_VOLUME, 
        input, ffi.sizeof(input), nil, 0, bytes, nil) == 0 then
        return false, util.format_error()
    end
    return true
end

function M.shrink(vol_handle, size_mb)
    if not size_mb or size_mb <= 0 then return false, "Invalid size" end
    local shrink = ffi.new("SHRINK_VOLUME_INFORMATION")
    shrink.ShrinkRequestType = 2 -- Commit
    shrink.Flags = 0
    
    local geo = ffi.new("DISK_GEOMETRY_EX")
    local bytes = ffi.new("DWORD[1]")
    if kernel32.DeviceIoControl(vol_handle, defs.IOCTL.DISK_GET_DRIVE_GEOMETRY_EX, 
        nil, 0, geo, ffi.sizeof(geo), bytes, nil) == 0 then
        return false, "GetGeometry failed"
    end
    
    local current_size = tonumber(geo.DiskSize.QuadPart)
    local target_size = current_size - (size_mb * 1024 * 1024)
    if target_size < 0 then return false, "Target size negative" end
    shrink.NewSize = target_size
    
    if kernel32.DeviceIoControl(vol_handle, defs.IOCTL.FSCTL_SHRINK_VOLUME, 
        shrink, ffi.sizeof(shrink), nil, 0, bytes, nil) == 0 then
        return false, util.format_error()
    end
    return true
end

-- [ENHANCED] Find, unmount, AND DISMOUNT all volumes
function M.unmount_all_on_disk(physical_drive_index)
    local volumes = M.list()
    if not volumes then return false end
    
    local count = 0
    for _, vol in ipairs(volumes) do
        local raw_path = vol.guid_path:sub(1, -2) 
        local hVol = M.open(raw_path) 
            
        if hVol then
            local extents = ffi.new("VOLUME_DISK_EXTENTS")
            local bytes = ffi.new("DWORD[1]")
            -- Get extents to see if this volume lives on our disk
            if kernel32.DeviceIoControl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, 
                nil, 0, extents, ffi.sizeof(extents), bytes, nil) ~= 0 then
                
                local belongs_to_disk = false
                for i = 0, extents.NumberOfDiskExtents - 1 do
                    if extents.Extents[i].DiskNumber == physical_drive_index then
                        belongs_to_disk = true
                        break
                    end
                end
                
                if belongs_to_disk then
                    -- 1. Unmount drive letters (Remove Access Points)
                    for _, mp in ipairs(vol.mount_points) do
                        if kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) ~= 0 then
                            count = count + 1
                        end
                    end
                    -- 2. Force Dismount (Invalidate Handles)
                    -- This effectively kills the filesystem cache and forces a re-mount on next access,
                    -- releasing locks held by the OS.
                    force_dismount(hVol)
                end
            end
            Handle.close(hVol)
        end
    end
    return true, count
end

function M.find_guid_by_partition(drive_index, partition_offset)
    local volumes = M.list()
    if volumes then
        for _, vol in ipairs(volumes) do
            local raw_path = vol.guid_path:sub(1, -2) 
            local hVol = M.open(raw_path) 
            if hVol then
                local extents = ffi.new("VOLUME_DISK_EXTENTS")
                local bytes = ffi.new("DWORD[1]")
                if kernel32.DeviceIoControl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, 
                    nil, 0, extents, ffi.sizeof(extents), bytes, nil) ~= 0 then
                    if extents.NumberOfDiskExtents > 0 then
                        local ext = extents.Extents[0]
                        if ext.DiskNumber == drive_index and 
                           tonumber(ext.StartingOffset.QuadPart) == partition_offset then
                            Handle.close(hVol)
                            return vol.guid_path
                        end
                    end
                end
                Handle.close(hVol)
            end
        end
    end

    -- Fallback
    local layout_mod = require 'win-utils.disk.layout'
    local phys_mod = require 'win-utils.disk.physical'
    local drive = phys_mod.open(drive_index)
    if not drive then return nil end
    local info = layout_mod.get_info(drive)
    drive:close()
    if not info then return nil end
    
    local partition_num = -1
    for _, p in ipairs(info.partitions) do
        if p.offset == partition_offset then partition_num = p.number; break end
    end
    
    if partition_num > 0 then
        local alias = string.format("Harddisk%dPartition%d", drive_index, partition_num)
        local target = M.resolve_dos_target(alias)
        if target then return "\\\\?\\GLOBALROOT" .. target .. "\\" end
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

function M.assign(drive_index, partition_offset, letter)
    local guid_path = M.find_guid_by_partition(drive_index, partition_offset)
    if not guid_path then return false, "Volume not found for partition" end
    
    local mount_point = letter
    if not mount_point then
        mount_point = M.find_free_letter()
        if not mount_point then return false, "No free drive letters" end
    end
    
    if #mount_point == 2 and mount_point:sub(2,2) == ":" then mount_point = mount_point .. "\\" end
    
    if kernel32.SetVolumeMountPointW(util.to_wide(mount_point), util.to_wide(guid_path)) == 0 then
        return false, util.format_error()
    end
    return true, mount_point
end

function M.remove_mount_point(mount_point)
    if #mount_point == 2 and mount_point:sub(2,2) == ":" then mount_point = mount_point .. "\\" end
    if kernel32.DeleteVolumeMountPointW(util.to_wide(mount_point)) == 0 then
        return false, util.format_error()
    end
    return true
end

function M.set_label(path, label)
    local root = path
    if #root == 2 and root:sub(2,2) == ":" then root = root .. "\\"
    elseif root:sub(-1) ~= "\\" then root = root .. "\\" end
    if kernel32.SetVolumeLabelW(util.to_wide(root), util.to_wide(label)) == 0 then
        return false, util.format_error()
    end
    return true
end

return M