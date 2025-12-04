local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.core.handle'
local C = require 'win-utils.core.ffi_defs'
local table_new = require 'table.new'

local M = {}

function M.list()
    local name = ffi.new("wchar_t[261]")
    local hFind = kernel32.FindFirstVolumeW(name, 261)
    if hFind == ffi.cast("HANDLE", -1) then return nil end
    
    local res = table_new(8, 0)
    
    ::continue_enum::
    
    local item = { 
        guid_path = util.from_wide(name), 
        mount_points = {} 
    }
    
    -- 获取挂载点列表
    local buf = ffi.new("wchar_t[1024]")
    local len = ffi.new("DWORD[1]")
    
    if kernel32.GetVolumePathNamesForVolumeNameW(name, buf, 1024, len) ~= 0 then
        local p = buf
        while true do
            local mp = util.from_wide(p)
            if not mp or mp == "" then break end
            table.insert(item.mount_points, mp)
            
            -- 移动指针到下一个字符串
            while p[0] ~= 0 do p = p + 1 end
            p = p + 1
            if p >= buf + len[0] then break end
        end
    end
    
    -- 获取卷标和文件系统
    local lab = ffi.new("wchar_t[261]")
    local fs = ffi.new("wchar_t[261]")
    if kernel32.GetVolumeInformationW(name, lab, 261, nil, nil, nil, fs, 261) ~= 0 then
        item.label = util.from_wide(lab)
        item.fs = util.from_wide(fs)
    end
    
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
        return nil, util.last_error() 
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
                -- 检查是否匹配物理盘号和偏移
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
    for i = 25, 2, -1 do -- Z: ... C:
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
    
    -- SetVolumeMountPoint 需要尾部反斜杠 (e.g. "X:\")
    if #mount_point == 2 then mount_point = mount_point .. "\\" end
    
    if kernel32.SetVolumeMountPointW(util.to_wide(mount_point), util.to_wide(guid_path)) == 0 then
        return false, util.last_error()
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
                -- 卸载所有挂载点 (盘符)
                for _, mp in ipairs(v.mount_points) do 
                    kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) 
                end
                -- 强制卸载卷本身 (强制关闭打开的句柄)
                util.ioctl(hVol:get(), defs.IOCTL.DISMOUNT)
            end
            hVol:close()
        end
    end
end

return M