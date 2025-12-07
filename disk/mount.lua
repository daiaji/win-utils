local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local M = {}

local function notify()
    if shell32 then shell32.SHChangeNotify(0x08000000, 0, nil, nil) end
end

function M.set_automount(en)
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return false, util.last_error("Open MountPointManager failed") end
    
    local s = ffi.new("int[1]", en and 1 or 0)
    local r, err = util.ioctl(h, 0x6D0040, s, 4) -- SET_AUTO_MOUNT
    
    kernel32.CloseHandle(h)
    
    if not r then return false, err end
    return true
end

function M.get_automount()
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return nil, util.last_error("Open MountPointManager failed") end
    
    local s, err = util.ioctl(h, 0x6D003C, nil, 0, "int") -- QUERY_AUTO_MOUNT
    
    kernel32.CloseHandle(h)
    
    if not s then return nil, err end
    return s[0] == 1
end

function M.find_free()
    local m = kernel32.GetLogicalDrives()
    for i=25,2,-1 do 
        if bit.band(m, bit.lshift(1, i)) == 0 then 
            return string.char(65+i)..":" 
        end 
    end
    return nil -- No free drive letters
end

function M.mount(drv, path)
    if not path:match("^%\\") then path = "\\??\\"..path end
    
    if kernel32.DefineDosDeviceW(0, util.to_wide(drv), util.to_wide(path)) == 0 then
        return false, util.last_error("DefineDosDevice failed")
    end
    
    notify()
    return true
end

function M.query(drv)
    local buf = ffi.new("wchar_t[1024]")
    if kernel32.QueryDosDeviceW(util.to_wide(drv), buf, 1024) == 0 then return nil end
    local t = util.from_wide(buf)
    if t and t:match("^%\\%?%?%\\") then return t:sub(5) end
    return t
end

function M.force_mount(drv, path)
    local t = path
    if t:match("^%\\%?%?%\\") then t = t:sub(5) end
    if not t:match("^%\\") then t = "\\??\\"..t end
    
    -- DDD_REMOVE_DEFINITION | DDD_RAW_TARGET_PATH (0x9 is weird combo, likely 0x1 | 0x8 ?)
    -- Assuming logic from original: 0x9
    if kernel32.DefineDosDeviceW(0x9, util.to_wide(drv), util.to_wide(t)) == 0 then
        return false, util.last_error("DefineDosDevice(Force) failed")
    end
    
    notify()
    return true
end

function M.unmount(drv) 
    if kernel32.DefineDosDeviceW(2, util.to_wide(drv), nil) == 0 then
        return false, util.last_error("DefineDosDevice(Remove) failed")
    end
    notify()
    return true
end

function M.temp_mount(idx, off)
    local layout = require('win-utils.disk.layout')
    local physical = require('win-utils.disk.physical')
    
    local d = physical.open(idx, "r")
    if not d then return nil end
    
    local info = layout.get(d)
    d:close()
    
    if not info then return nil end
    for _,p in ipairs(info.parts) do
        if p.off == off then
            local t = string.format("\\Device\\Harddisk%d\\Partition%d", idx, p.num)
            local l = M.find_free()
            if l and M.mount(l, t) then return l end
        end
    end
    return nil
end

function M.unmount_all(idx)
    local vol = require('win-utils.disk.volume')
    local list = vol.list()
    if not list then return end
    
    local changed = false
    for _, v in ipairs(list) do
        local h = vol.open(v.guid_path)
        if h then
            local ext = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == idx then
                for _, mp in ipairs(v.mount_points) do 
                    M.unmount(mp:sub(1,2)) 
                    changed = true
                end
                util.ioctl(h:get(), defs.IOCTL.DISMOUNT)
            end
            h:close()
        end
    end
    if changed then notify() end
end

-- [FIX] Added alias to support 'unmount_all_on_disk' as called by tests and init.lua
M.unmount_all_on_disk = M.unmount_all

return M