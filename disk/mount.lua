local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

local MOUNTMGR_DOS_DEVICE_NAME = "\\\\.\\MountPointManager"

function M.set_automount(enable)
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    local hMountMgr = kernel32.CreateFileW(util.to_wide(MOUNTMGR_DOS_DEVICE_NAME), 
        0, share, nil, C.OPEN_EXISTING, 0, nil) 
        
    if hMountMgr == ffi.cast("HANDLE", -1) then 
        return false, "Open MountManager failed: " .. util.format_error() 
    end
    
    local state = ffi.new("MOUNTMGR_AUTO_MOUNT_STATE[1]")
    state[0] = enable and 1 or 0 -- Enabled/Disabled
    
    local bytes = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(hMountMgr, C.IOCTL_MOUNTMGR_SET_AUTO_MOUNT, 
        state, ffi.sizeof("MOUNTMGR_AUTO_MOUNT_STATE"), nil, 0, bytes, nil)
        
    kernel32.CloseHandle(hMountMgr)
    
    if res == 0 then return false, util.format_error() end
    return true
end

function M.get_automount()
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    local hMountMgr = kernel32.CreateFileW(util.to_wide(MOUNTMGR_DOS_DEVICE_NAME), 
        0, share, nil, C.OPEN_EXISTING, 0, nil)
        
    if hMountMgr == ffi.cast("HANDLE", -1) then return nil end
    
    local state = ffi.new("MOUNTMGR_AUTO_MOUNT_STATE[1]")
    local bytes = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(hMountMgr, C.IOCTL_MOUNTMGR_QUERY_AUTO_MOUNT, 
        nil, 0, state, ffi.sizeof("MOUNTMGR_AUTO_MOUNT_STATE"), bytes, nil)
        
    kernel32.CloseHandle(hMountMgr)
    
    if res == 0 then return nil end
    return (state[0] == 1) -- Enabled
end

function M.force_mount(letter, target_path)
    local dos_name = letter:sub(1,2) 
    
    local clean_target = target_path:gsub("\\$", "")
    
    if clean_target:find("^\\\\%?\\GLOBALROOT") then
        clean_target = clean_target:sub(15) 
    elseif clean_target:find("^\\\\%?\\") then
        clean_target = clean_target:sub(5) 
    end
    
    local flags = bit.bor(C.DDD_RAW_TARGET_PATH, C.DDD_NO_BROADCAST_SYSTEM)
    if kernel32.DefineDosDeviceW(flags, util.to_wide(dos_name), util.to_wide(clean_target)) == 0 then
        return false, util.format_error()
    end
    return true
end

function M.force_unmount(letter)
    local dos_name = letter:sub(1,2)
    local flags = bit.bor(C.DDD_REMOVE_DEFINITION, C.DDD_NO_BROADCAST_SYSTEM)
    if kernel32.DefineDosDeviceW(flags, util.to_wide(dos_name), nil) == 0 then
        return false, util.format_error()
    end
    return true
end

return M