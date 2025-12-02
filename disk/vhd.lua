local ffi = require 'ffi'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local virtdisk = require 'ffi.req' 'Windows.sdk.virtdisk'
-- [FIX] Load kernel32 at module level for performance
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local C = virtdisk

-- Microsoft Vendor ID: {EC984AEC-A0F9-47e9-901F-71415A66345B}
local VENDOR_MS = ffi.new("GUID", {0xEC984AEC, 0xA0F9, 0x47e9, {0x90, 0x1F, 0x71, 0x41, 0x5A, 0x66, 0x34, 0x5B}})

function M.create(path, size_bytes)
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    vst.VendorId = VENDOR_MS
    
    -- Auto-detect VHDX based on extension
    if path:lower():match("%.vhdx$") then
        vst.DeviceId = C.VIRTUAL_STORAGE_TYPE_DEVICE_VHDX
    else
        vst.DeviceId = C.VIRTUAL_STORAGE_TYPE_DEVICE_VHD
    end

    local params = ffi.new("CREATE_VIRTUAL_DISK_PARAMETERS")
    params.Version = 2
    params.Version2.MaximumSize = size_bytes
    
    local handle = ffi.new("HANDLE[1]")
    
    local res = virtdisk.CreateVirtualDisk(vst, util.to_wide(path), 
        C.VIRTUAL_DISK_ACCESS_ALL, 
        nil, 
        C.CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION,
        0, params, nil, handle)
        
    if res ~= 0 then return nil, "Create failed: " .. res end
    
    return Handle.guard(handle[0])
end

function M.open(path)
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    -- Use DEVICE_UNKNOWN (0) to let Windows automatically detect VHD vs VHDX
    vst.DeviceId = C.VIRTUAL_STORAGE_TYPE_DEVICE_UNKNOWN
    vst.VendorId = VENDOR_MS
    
    local handle = ffi.new("HANDLE[1]")
    
    local res = virtdisk.OpenVirtualDisk(vst, util.to_wide(path), 
        C.VIRTUAL_DISK_ACCESS_ALL, 
        C.OPEN_VIRTUAL_DISK_FLAG_NONE, 
        nil, handle)
        
    if res ~= 0 then return nil, "Open failed: " .. res end
    return Handle.guard(handle[0])
end

function M.attach(vhd_handle)
    local res = virtdisk.AttachVirtualDisk(vhd_handle, nil, C.ATTACH_VIRTUAL_DISK_FLAG_NONE, 0, nil, nil)
    return res == 0
end

function M.detach(vhd_handle)
    local res = virtdisk.DetachVirtualDisk(vhd_handle, C.DETACH_VIRTUAL_DISK_FLAG_NONE, 0)
    return res == 0
end

function M.expand(vhd_handle, new_size_bytes)
    local params = ffi.new("EXPAND_VIRTUAL_DISK_PARAMETERS")
    params.Version = 1
    params.Version1.NewSize = new_size_bytes
    
    local res = virtdisk.ExpandVirtualDisk(vhd_handle, C.EXPAND_VIRTUAL_DISK_FLAG_NONE, params, nil)
    if res ~= 0 then return false, "Expand failed: " .. res end
    return true
end

function M.get_physical_path(vhd_handle)
    local size = ffi.new("DWORD[1]", 260*2)
    local buf = ffi.new("wchar_t[260]")
    
    local res = virtdisk.GetVirtualDiskPhysicalPath(vhd_handle, size, buf)
    if res ~= 0 then return nil end
    
    return util.from_wide(buf)
end

function M.wait_for_physical_path(vhd_handle, timeout_ms)
    -- [FIX] Use module-level kernel32 reference
    local start = kernel32.GetTickCount()
    local path = nil
    
    while true do
        path = M.get_physical_path(vhd_handle)
        if path then break end
        
        if (kernel32.GetTickCount() - start) > timeout_ms then
            return nil, "Timeout waiting for VHD mount"
        end
        kernel32.Sleep(100)
    end
    
    return path
end

return M