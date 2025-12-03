local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'
local registry = require 'win-utils.registry'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 检查指定物理磁盘是否包含当前运行的 Windows 系统
function M.is_system_drive(drive_index)
    local win_dir = ffi.new("wchar_t[260]")
    if kernel32.GetWindowsDirectoryW(win_dir, 260) == 0 then return false end
    
    -- 获取系统盘符 (例如 "C:")
    local drive_letter = util.from_wide(win_dir):sub(1, 2)
    local vol_path = "\\\\.\\" .. drive_letter
    
    local hVol = kernel32.CreateFileW(util.to_wide(vol_path), 
        0, bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, C.OPEN_EXISTING, 0, nil)
        
    if hVol == ffi.cast("HANDLE", -1) then return false end
    local safe_hVol = Handle.new(hVol)
    
    local extents = util.ioctl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    
    if extents then
        for i = 0, extents.NumberOfDiskExtents - 1 do
            if extents.Extents[i].DiskNumber == drive_index then
                return true
            end
        end
    end
    
    return false
end

-- 检查指定物理磁盘是否包含页面文件
function M.has_pagefile(drive_index)
    local key = registry.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management")
    if not key then return false end
    
    local paging_files = key:read("PagingFiles")
    key:close()
    
    if not paging_files then return false end
    if type(paging_files) ~= "table" then paging_files = { paging_files } end
    
    for _, entry in ipairs(paging_files) do
        -- 提取盘符 (例如 "C:\pagefile.sys" -> "C:")
        local drive_letter = entry:sub(1, 2)
        local vol_path = "\\\\.\\" .. drive_letter
        
        local hVol = kernel32.CreateFileW(util.to_wide(vol_path), 0, bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE), nil, C.OPEN_EXISTING, 0, nil)
        
        if hVol ~= ffi.cast("HANDLE", -1) then
            local extents = util.ioctl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            kernel32.CloseHandle(hVol)
            
            if extents then
                for i = 0, extents.NumberOfDiskExtents - 1 do
                    if extents.Extents[i].DiskNumber == drive_index then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- 检查注册表中的写保护策略
function M.check_write_protect_policy()
    local key = registry.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\StorageDevicePolicies")
    if key then
        local val = key:read("WriteProtect")
        key:close()
        if val == 1 then return true end
    end
    return false
end

return M