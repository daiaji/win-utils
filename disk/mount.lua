local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32' -- For SHChangeNotify
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local M = {}

-- [RESTORED] Notify shell of drive changes
local function notify()
    -- SHCNE_DRIVEADD=0x100, SHCNE_DRIVEREMOVED=0x80, SHCNE_ASSOCCHANGED=0x08000000
    -- Using ASSOCCHANGED as a catch-all refresh is usually effective enough
    if shell32 then shell32.SHChangeNotify(0x08000000, 0, nil, nil) end
end

function M.set_automount(en)
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return false end
    local s = ffi.new("int[1]", en and 1 or 0)
    local r = util.ioctl(h, 0x6D0040, s, 4) -- SET_AUTO_MOUNT
    kernel32.CloseHandle(h)
    return r ~= nil
end

function M.get_automount()
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return nil end
    local s = util.ioctl(h, 0x6D003C, nil, 0, "int") -- QUERY_AUTO_MOUNT
    kernel32.CloseHandle(h)
    return s and s[0] == 1
end

function M.find_free()
    local m = kernel32.GetLogicalDrives()
    for i=25,2,-1 do if bit.band(m, bit.lshift(1, i))==0 then return string.char(65+i)..":" end end
end

function M.mount(drv, path)
    if not path:match("^%\\") then path = "\\??\\"..path end
    local ok = kernel32.DefineDosDeviceW(0, util.to_wide(drv), util.to_wide(path)) ~= 0
    if ok then notify() end
    return ok
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
    local ok = kernel32.DefineDosDeviceW(0x9, util.to_wide(drv), util.to_wide(t)) ~= 0
    if ok then notify() end
    return ok
end

function M.unmount(drv) 
    local ok = kernel32.DefineDosDeviceW(2, util.to_wide(drv), nil) ~= 0
    if ok then notify() end
    return ok
end

function M.temp_mount(idx, off)
    local layout = require('win-utils.disk.layout')
    local d = require('win-utils.disk.physical').open(idx, "r")
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

return M