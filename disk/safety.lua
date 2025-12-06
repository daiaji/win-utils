local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local reg = require 'win-utils.reg.init'
local native = require 'win-utils.core.native'

local M = {}

-- 检查驱动器是否包含当前运行的 Windows
function M.is_system_drive(drive_idx)
    local buf = ffi.new("wchar_t[260]")
    if kernel32.GetWindowsDirectoryW(buf, 260) == 0 then return nil, util.last_error() end
    
    -- 获取 C:
    local letter = util.from_wide(buf):sub(1, 2)
    local h = native.open_file("\\\\.\\" .. letter, "r", true)
    if not h then return nil, "Failed to open system drive handle" end
    
    local ext, err = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    h:close()
    
    if ext then
        for i = 0, ext.NumberOfDiskExtents - 1 do
            if ext.Extents[i].DiskNumber == drive_idx then return true end
        end
    end
    return false
end

-- 检查是否存在活跃页面文件
function M.has_pagefile(drive_idx)
    local k = reg.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management")
    if not k then return false end
    
    local files = k:read("PagingFiles")
    k:close()
    if not files then return false end
    if type(files) ~= "table" then files = {files} end
    
    for _, path in ipairs(files) do
        local letter = path:sub(1, 2)
        if letter:match("^%a:") then
            local h = native.open_file("\\\\.\\" .. letter, "r", true)
            if h then
                local ext = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
                h:close()
                if ext then
                    for i = 0, ext.NumberOfDiskExtents - 1 do
                        if ext.Extents[i].DiskNumber == drive_idx then return true end
                    end
                end
            end
        end
    end
    return false
end

-- 检查写保护注册表策略
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