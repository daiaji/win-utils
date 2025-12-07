local ffi = require 'ffi'
local virtdisk = require 'ffi.req' 'Windows.sdk.virtdisk'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local bit = require 'bit'

local M = {}
local C = virtdisk
local VENDOR_MS = ffi.new("GUID", {0xEC984AEC, 0xA0F9, 0x47e9, {0x90, 0x1F, 0x71, 0x41, 0x5A, 0x66, 0x34, 0x5B}})

function M.create(path, size_bytes, opts)
    opts = opts or {}
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    vst.VendorId = VENDOR_MS
    vst.DeviceId = path:lower():match("%.vhdx$") and 3 or 2

    local params = ffi.new("CREATE_VIRTUAL_DISK_PARAMETERS")
    params.Version = 2
    params.Version2.MaximumSize = size_bytes
    
    -- [Rufus Strategy] 使用 Full Physical Allocation 避免动态扩容导致的 I/O 挂起
    -- 0x08 = CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION
    -- 默认为 Full Physical (0x08)，除非显式请求 dynamic
    local flags = 0
    if opts.dynamic then
        flags = 0
    else
        flags = 0x08 
    end
    
    local h = ffi.new("HANDLE[1]")
    local res = C.CreateVirtualDisk(vst, util.to_wide(path), 0, nil, flags, 0, params, nil, h)
    
    if res ~= 0 then return nil, "CreateVirtualDisk failed: " .. res end
    return Handle(h[0])
end

function M.open(path)
    local vst = ffi.new("VIRTUAL_STORAGE_TYPE")
    vst.DeviceId = 0
    vst.VendorId = VENDOR_MS
    
    local h = ffi.new("HANDLE[1]")
    local res = C.OpenVirtualDisk(vst, util.to_wide(path), 0x30000, 0, nil, h)
    
    if res ~= 0 then return nil, "OpenVirtualDisk failed: " .. res end
    return Handle(h[0])
end

function M.attach(h) 
    -- ATTACH_VIRTUAL_DISK_FLAG_NO_DRIVE_LETTER = 0x00000002 (防止自动分配盘符干扰)
    local flags = 0x00000002 
    local res = C.AttachVirtualDisk(h:get(), nil, flags, 0, nil, nil)
    if res ~= 0 then return false, "Attach failed: " .. res end
    return true
end

function M.detach(h) 
    local res = C.DetachVirtualDisk(h:get(), 0, 0)
    if res ~= 0 then return false, "Detach failed: " .. res end
    return true
end

function M.expand(h, new_size)
    local p = ffi.new("EXPAND_VIRTUAL_DISK_PARAMETERS")
    p.Version = 1; p.Version1.NewSize = new_size
    local res = C.ExpandVirtualDisk(h:get(), 0, p, nil)
    if res ~= 0 then return false, "Expand failed: " .. res end
    return true
end

function M.get_physical_path(h)
    local raw_h = (type(h) == "table" and h.get) and h:get() or h
    local sz = ffi.new("DWORD[1]", 520)
    local buf = ffi.new("wchar_t[260]")
    if C.GetVirtualDiskPhysicalPath(raw_h, sz, buf) ~= 0 then return nil end
    return util.from_wide(buf)
end

function M.wait_for_physical_path(h, timeout)
    local start = kernel32.GetTickCount()
    local limit = timeout or 10000
    while true do
        local path = M.get_physical_path(h)
        if path then return path end
        if (kernel32.GetTickCount() - start) > limit then return nil, "Timeout waiting for physical path" end
        kernel32.Sleep(100)
    end
end

return M