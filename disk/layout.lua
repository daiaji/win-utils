local ffi = require 'ffi'
local defs = require 'win-utils.disk.defs'
local types = require 'win-utils.disk.types'
local util = require 'win-utils.core.util'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
require 'ffi.req' 'Windows.sdk.winioctl'

local M = {}

local function get_raw(d)
    local sz = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local buf = ffi.new("uint8_t[?]", sz)
    local ok, err = d:ioctl(defs.IOCTL.GET_LAYOUT, nil, 0, buf, sz)
    if not ok then return nil, err end
    return ffi.cast("DRIVE_LAYOUT_INFORMATION_EX_FULL*", buf), sz
end

local function set_raw(d, l, sz)
    local ok, err = d:ioctl(defs.IOCTL.SET_LAYOUT, l, sz)
    if not ok then return false, err end
    d:ioctl(defs.IOCTL.UPDATE)
    return true
end

function M.get(d)
    local raw, err = get_raw(d)
    if not raw then return nil, err end
    
    local res = { style = (raw.PartitionStyle==1) and "GPT" or "MBR", parts={} }
    for i=0, raw.PartitionCount-1 do
        local p = raw.PartitionEntry[i]
        local valid = (res.style=="GPT") and (p.PartitionLength.QuadPart > 0) or (p.Mbr.PartitionType ~= 0)
        if valid then
            table.insert(res.parts, {
                num = p.PartitionNumber, 
                off = tonumber(p.StartingOffset.QuadPart), 
                len = tonumber(p.PartitionLength.QuadPart),
                type = (res.style=="GPT") and util.guid_to_str(p.Gpt.PartitionType) or p.Mbr.PartitionType,
                attr = (res.style=="GPT") and p.Gpt.Attributes or 0
            })
        end
    end
    return res
end

function M.apply(d, scheme, parts)
    local sz = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local l = ffi.new("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local cr = ffi.new("CREATE_DISK")
    
    cr.PartitionStyle = (scheme=="GPT") and 1 or 0
    if scheme=="GPT" then 
        ole32.CoCreateGuid(cr.Gpt.DiskId)
        cr.Gpt.MaxPartitionCount = 128 
    else 
        cr.Mbr.Signature = os.time() 
    end
    
    local ok, err = d:ioctl(defs.IOCTL.CREATE, cr)
    if not ok then return false, "CreateDisk failed: " .. tostring(err) end
    d:ioctl(defs.IOCTL.UPDATE)
    
    l.PartitionStyle = cr.PartitionStyle
    l.PartitionCount = #parts
    if scheme=="GPT" then
        l.Gpt.DiskId = cr.Gpt.DiskId
        l.Gpt.StartingUsableOffset.QuadPart = 34 * d.sector_size
        l.Gpt.UsableLength.QuadPart = d.size - (67 * d.sector_size)
        l.Gpt.MaxPartitionCount = 128
    else 
        l.Mbr.Signature = cr.Mbr.Signature 
    end
    
    for i, p in ipairs(parts) do
        local e = l.PartitionEntry[i-1]
        e.PartitionStyle = l.PartitionStyle
        e.StartingOffset.QuadPart = p.offset
        e.PartitionLength.QuadPart = p.size
        e.PartitionNumber = i
        e.RewritePartition = 1
        if scheme=="GPT" then
            e.Gpt.PartitionType = util.guid_from_str(p.gpt_type)
            ole32.CoCreateGuid(e.Gpt.PartitionId)
            local n = util.to_wide(p.name or ""); ffi.copy(e.Gpt.Name, n, ffi.sizeof(n))
            e.Gpt.Attributes = p.attr or 0
        else
            e.Mbr.PartitionType = p.mbr_type
            e.Mbr.BootIndicator = p.active and 0x80 or 0
        end
    end
    
    if not set_raw(d, l, sz) then return false, util.last_error("SetLayout failed") end
    
    local wipe_buf = kernel32.VirtualAlloc(nil, d.sector_size, 0x1000, 0x04)
    if wipe_buf then
        for _, p in ipairs(parts) do
            d:write_sectors(p.offset, ffi.string(wipe_buf, d.sector_size))
        end
        kernel32.VirtualFree(wipe_buf, 0, 0x8000)
    end
    
    return true
end

function M.calculate_partition_plan(drive, scheme, opts)
    opts = opts or {}
    local parts = {}
    local ONE_MB = 1048576
    local off = ONE_MB
    local limit = drive.size
    if scheme == "GPT" then limit = limit - (33 * drive.sector_size) end
    
    if scheme == "GPT" and opts.create_msr then
        local sz = 128 * ONE_MB
        table.insert(parts, { type="MSR", offset=off, size=sz, gpt_type=types.GPT.MSR, name="Microsoft Reserved Partition" })
        off = off + sz
    end
    
    if opts.create_esp then
        local sz = 260 * ONE_MB
        table.insert(parts, { type="ESP", offset=off, size=sz, gpt_type=types.GPT.ESP, mbr_type=types.MBR.ESP, name="EFI System Partition" })
        off = off + sz
    end
    
    local rem = limit - off
    if opts.cluster_size then rem = math.floor(rem / opts.cluster_size) * opts.cluster_size end
    
    if rem > 0 then
        table.insert(parts, { type="DATA", offset=off, size=rem, gpt_type=types.GPT.DATA, mbr_type=types.MBR.NTFS, name="Basic Data Partition" })
    end
    return parts
end

function M.set_active(d, idx, act)
    local l, sz = get_raw(d)
    if not l then return false, "GetLayout failed" end
    if l.PartitionStyle ~= 0 then return false, "Not MBR" end
    
    for i=0, l.PartitionCount-1 do
        local p = l.PartitionEntry[i]
        if p.Mbr.PartitionType ~= 0 then
            p.Mbr.BootIndicator = (p.PartitionNumber == idx and act) and 0x80 or 0
            p.RewritePartition = 1
        end
    end
    return set_raw(d, l, sz)
end

function M.set_partition_attributes(d, idx, attr)
    local l, sz = get_raw(d)
    if not l then return false, "GetLayout failed" end
    if l.PartitionStyle ~= 1 then return false, "Not GPT" end
    
    for i=0, l.PartitionCount-1 do
        local p = l.PartitionEntry[i]
        if p.PartitionNumber == idx then 
            p.Gpt.Attributes = attr
            p.RewritePartition = 1 
        end
    end
    return set_raw(d, l, sz)
end

function M.set_partition_type(d, idx, tid)
    local l, sz = get_raw(d)
    if not l then return false, "GetLayout failed" end
    
    for i=0, l.PartitionCount-1 do
        local p = l.PartitionEntry[i]
        if p.PartitionNumber == idx then
            if l.PartitionStyle == 1 then p.Gpt.PartitionType = util.guid_from_str(tid)
            else p.Mbr.PartitionType = tid end
            p.RewritePartition = 1
        end
    end
    return set_raw(d, l, sz)
end

return M