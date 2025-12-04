local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local reg = require 'win-utils.reg.init'
local native = require 'win-utils.core.native'

local M = {}

-- 检查物理磁盘是否包含当前 Windows 系统
function M.is_system_drive(drive_idx)
    local buf = ffi.new("wchar_t[260]")
    if kernel32.GetWindowsDirectoryW(buf, 260) == 0 then return false end
    local letter = util.from_wide(buf):sub(1, 2)
    local h = native.open_file("\\\\.\\" .. letter, "r")
    if not h then return false end
    
    local ext = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    h:close()
    
    if ext then
        for i = 0, ext.NumberOfDiskExtents - 1 do
            if ext.Extents[i].DiskNumber == drive_idx then return true end
        end
    end
    return false
end

-- 检查物理磁盘是否有页面文件
function M.has_pagefile(drive_idx)
    local k = reg.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management")
    if not k then return false end
    local pfs = k:read("PagingFiles")
    k:close()
    if not pfs then return false end
    if type(pfs) ~= "table" then pfs = { pfs } end
    
    for _, ent in ipairs(pfs) do
        local l = ent:match("^(%a:)")
        if l then
            local h = native.open_file("\\\\.\\" .. l, "r")
            if h then
                local ext = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
                h:close()
                if ext then
                    for i=0, ext.NumberOfDiskExtents-1 do
                        if ext.Extents[i].DiskNumber == drive_idx then return true end
                    end
                end
            end
        end
    end
    return false
end

-- 检查写保护策略
function M.check_write_protect_policy()
    local k = reg.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\StorageDevicePolicies")
    if k then
        local v = k:read("WriteProtect")
        k:close()
        return v == 1
    end
    return false
end

return M