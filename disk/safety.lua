local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'
local registry = require 'win-utils.registry'

local M = {}
local C = ffi.C

function M.is_system_drive(physical_drive_index)
    local win_dir = ffi.new("wchar_t[260]")
    kernel32.GetWindowsDirectoryW(win_dir, 260)
    
    -- Extract Drive Letter (e.g., "C:\") from Windows Directory
    local root_path_w = ffi.new("wchar_t[4]")
    root_path_w[0] = win_dir[0]; root_path_w[1] = 58; root_path_w[2] = 92; root_path_w[3] = 0

    -- Convert Wide "C:\" -> Lua "C:\" -> Lua "\\.\C:" -> Wide "\\.\C:"
    -- [FIX] Correctly handle Wide Char conversion for CreateFileW
    local root_lua = util.from_wide(root_path_w, 2) -- "C:"
    local device_path = string.format("\\\\.\\%s", root_lua)
    local device_path_w = util.to_wide(device_path)

    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    
    local hVol = kernel32.CreateFileW(device_path_w, 
        0, share, nil, C.OPEN_EXISTING, 0, nil)
    
    if hVol == ffi.cast("HANDLE", -1) then return false end 

    local extents = ffi.new("VOLUME_DISK_EXTENTS")
    local bytes = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, extents, ffi.sizeof(extents), bytes, nil)
    kernel32.CloseHandle(hVol)

    if res == 0 then return false end

    for i = 0, extents.NumberOfDiskExtents - 1 do
        if extents.Extents[i].DiskNumber == physical_drive_index then
            return true
        end
    end
    return false
end

function M.has_pagefile(physical_drive_index)
    local key = registry.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management")
    if not key then return false end
    
    local paging_files = key:read("PagingFiles")
    key:close()
    
    if not paging_files then return false end
    if type(paging_files) ~= "table" then paging_files = { paging_files } end
    
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    for _, entry in ipairs(paging_files) do
        local drive_letter = entry:sub(1, 2)
        local hVol = kernel32.CreateFileW(util.to_wide("\\\\.\\" .. drive_letter), 0, share, nil, C.OPEN_EXISTING, 0, nil)
            
        if hVol ~= ffi.cast("HANDLE", -1) then
            local extents = ffi.new("VOLUME_DISK_EXTENTS")
            local bytes = ffi.new("DWORD[1]")
            if kernel32.DeviceIoControl(hVol, defs.IOCTL.VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, extents, ffi.sizeof(extents), bytes, nil) ~= 0 then
                for i = 0, extents.NumberOfDiskExtents - 1 do
                    if extents.Extents[i].DiskNumber == physical_drive_index then
                        kernel32.CloseHandle(hVol)
                        return true
                    end
                end
            end
            kernel32.CloseHandle(hVol)
        end
    end
    return false
end

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