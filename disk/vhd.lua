local ffi = require 'ffi'
local virtdisk = require 'ffi.req' 'Windows.sdk.virtdisk'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local C = virtdisk
local VENDOR_MS = ffi.new("GUID", {0xEC984AEC, 0xA0F9, 0x47e9, {0x90, 0x1F, 0x71, 0x41, 0x5A, 0x66, 0x34, 0x5B}})

local M = {}

function M.create(path, size_bytes)
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    vst.VendorId = VENDOR_MS
    vst.DeviceId = path:lower():match("%.vhdx$") and 3 or 2

    local params = ffi.new("CREATE_VIRTUAL_DISK_PARAMETERS")
    params.Version = 2
    params.Version2.MaximumSize = size_bytes
    
    local h = ffi.new("HANDLE[1]")
    -- VIRTUAL_DISK_ACCESS_ALL | VIRTUAL_DISK_ACCESS_CREATE
    local res = C.CreateVirtualDisk(vst, util.to_wide(path), 0x30000, nil, 8, 0, params, nil, h)
    
    if res ~= 0 then return nil, "Create failed: " .. res end
    return Handle.new(h[0])
end

function M.open(path)
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    vst.DeviceId = 0 -- Unknown (Auto)
    vst.VendorId = VENDOR_MS
    
    local h = ffi.new("HANDLE[1]")
    local res = C.OpenVirtualDisk(vst, util.to_wide(path), 0x30000, 0, nil, h)
    
    if res ~= 0 then return nil, "Open failed: " .. res end
    return Handle.new(h[0])
end

function M.attach(h) 
    return C.AttachVirtualDisk(h:get(), nil, 0, 0, nil, nil) == 0 
end

function M.detach(h) 
    return C.DetachVirtualDisk(h:get(), 0, 0) == 0 
end

function M.expand(h, new_size)
    local p = ffi.new("EXPAND_VIRTUAL_DISK_PARAMETERS")
    p.Version = 1; p.Version1.NewSize = new_size
    return C.ExpandVirtualDisk(h:get(), 0, p, nil) == 0
end

function M.get_physical_path(h)
    local sz = ffi.new("DWORD[1]", 520)
    local buf = ffi.new("wchar_t[260]")
    if C.GetVirtualDiskPhysicalPath(h:get(), sz, buf) ~= 0 then return nil end
    return util.from_wide(buf)
end

function M.wait_for_physical_path(h, timeout)
    local start = kernel32.GetTickCount()
    local limit = timeout or 10000
    while true do
        local path = M.get_physical_path(h)
        if path then return path end
        if (kernel32.GetTickCount() - start) > limit then return nil, "Timeout" end
        kernel32.Sleep(100)
    end
end

return M