local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
local defs = require 'win-utils.disk.defs'
local types = require 'win-utils.disk.types'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'

local M = {}
local C = ffi.C

-- 辅助：获取原始布局结构
local function get_raw_layout(drive)
    return util.ioctl(drive:get(), defs.IOCTL.DISK_GET_DRIVE_LAYOUT_EX, nil, 0, "DRIVE_LAYOUT_INFORMATION_EX_FULL")
end

-- 辅助：应用布局
local function set_layout(drive, layout)
    local sz = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    if not util.ioctl(drive:get(), defs.IOCTL.DISK_SET_DRIVE_LAYOUT_EX, layout, sz) then
        return false, util.format_error()
    end
    util.ioctl(drive:get(), defs.IOCTL.DISK_UPDATE_PROPERTIES)
    return true
end

function M.get_raw_layout(drive) return get_raw_layout(drive) end

function M.get_info(drive)
    local layout = get_raw_layout(drive)
    if not layout then return nil, "GetLayout failed" end
    
    local info = { style = (layout.PartitionStyle == 0) and "MBR" or "GPT", partitions = {} }
    if info.style == "MBR" then 
        info.signature = layout.Mbr.Signature 
    else 
        info.disk_id = layout.Gpt.DiskId 
    end
    
    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        -- 过滤 MBR 空分区
        if not (info.style == "MBR" and p.Mbr.PartitionType == 0) then
            local item = {
                number = p.PartitionNumber,
                index = i + 1,
                offset = tonumber(p.StartingOffset.QuadPart),
                length = tonumber(p.PartitionLength.QuadPart)
            }
            if info.style == "MBR" then
                item.type = p.Mbr.PartitionType
                item.active = p.Mbr.BootIndicator ~= 0
                item.hidden = p.Mbr.HiddenSectors
            else
                item.type_guid = p.Gpt.PartitionType
                item.id = p.Gpt.PartitionId
                item.attr = p.Gpt.Attributes -- cdata int64
                item.name = util.from_wide(p.Gpt.Name)
            end
            table.insert(info.partitions, item)
        end
    end
    return info
end

function M.set_active(drive, part_idx, active)
    local layout = get_raw_layout(drive)
    if not layout then return false end
    if layout.PartitionStyle ~= 0 then return false, "Not MBR" end
    
    local found = false
    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        if p.Mbr.PartitionType ~= 0 then
            if active then p.Mbr.BootIndicator = 0 end -- 清除其他激活标记
            if p.PartitionNumber == part_idx then
                p.Mbr.BootIndicator = active and 0x80 or 0
                p.RewritePartition = 1
                found = true
            end
        end
    end
    if not found then return false, "Partition not found" end
    return set_layout(drive, layout)
end

function M.set_partition_type(drive, part_idx, type_id)
    local layout = get_raw_layout(drive)
    if not layout then return false end
    
    local found = false
    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        if p.PartitionNumber == part_idx then
            if layout.PartitionStyle == 1 then -- GPT
                if type(type_id) ~= "string" then return false, "GPT requires GUID string" end
                p.Gpt.PartitionType = util.guid_from_str(type_id)
            else
                if type(type_id) ~= "number" then return false, "MBR requires int ID" end
                p.Mbr.PartitionType = type_id
            end
            p.RewritePartition = 1
            found = true
            break
        end
    end
    if not found then return false, "Partition not found" end
    return set_layout(drive, layout)
end

function M.set_partition_attributes(drive, part_idx, attrs)
    local layout = get_raw_layout(drive)
    if not layout then return false end
    if layout.PartitionStyle ~= 1 then return false, "Not GPT" end
    
    local found = false
    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        if p.PartitionNumber == part_idx then
            p.Gpt.Attributes = attrs
            p.RewritePartition = 1
            found = true
            break
        end
    end
    if not found then return false, "Partition not found" end
    return set_layout(drive, layout)
end

function M.calculate_partition_plan(drive, scheme, opts)
    opts = opts or {}
    local parts = {}
    local ONE_MB = 1048576
    local offset = ONE_MB -- 1MB Alignment
    local total = drive.size
    
    -- GPT Footer space
    local limit = total
    if scheme == "GPT" then limit = limit - (33 * drive.sector_size) end
    
    if scheme == "GPT" and opts.create_msr then
        local sz = 128 * ONE_MB
        table.insert(parts, { 
            type="MSR", offset=offset, size=sz, 
            gpt_type=types.GPT.MSR, name="Microsoft Reserved Partition" 
        })
        offset = offset + sz
    end
    
    if opts.create_esp then
        local sz = 260 * ONE_MB
        table.insert(parts, { 
            type="ESP", offset=offset, size=sz, 
            gpt_type=types.GPT.ESP, mbr_type=types.MBR.ESP, 
            name="EFI System Partition" 
        })
        offset = offset + sz
    end
    
    local remain = limit - offset
    if opts.cluster_size then 
        remain = math.floor(remain / opts.cluster_size) * opts.cluster_size 
    end
    
    -- Data Partition
    if remain > 0 then
        table.insert(parts, { 
            type="DATA", offset=offset, size=remain, 
            gpt_type=types.GPT.BASIC_DATA, mbr_type=types.MBR.NTFS, 
            name="Basic Data Partition" 
        })
    end
    return parts
end

function M.apply_partition_plan(drive, scheme, parts)
    -- 1. Initialize Disk
    local create = ffi.new("CREATE_DISK")
    create.PartitionStyle = (scheme == "GPT") and 1 or 0
    if scheme == "GPT" then 
        ole32.CoCreateGuid(create.Gpt.DiskId)
        create.Gpt.MaxPartitionCount = 128
    else 
        create.Mbr.Signature = os.time() 
    end
    
    if not util.ioctl(drive:get(), defs.IOCTL.DISK_CREATE_DISK, create) then 
        return false, "Init failed: " .. util.format_error() 
    end
    util.ioctl(drive:get(), defs.IOCTL.DISK_UPDATE_PROPERTIES)
    
    -- 2. Construct Layout
    local layout = ffi.new("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    layout.PartitionStyle = create.PartitionStyle
    layout.PartitionCount = #parts
    
    if scheme == "GPT" then
        layout.Gpt.DiskId = create.Gpt.DiskId
        layout.Gpt.MaxPartitionCount = 128
        layout.Gpt.StartingUsableOffset.QuadPart = 34 * drive.sector_size
        layout.Gpt.UsableLength.QuadPart = drive.size - (67 * drive.sector_size)
    else
        layout.Mbr.Signature = create.Mbr.Signature
    end
    
    for i, p in ipairs(parts) do
        local e = layout.PartitionEntry[i-1]
        e.PartitionStyle = layout.PartitionStyle
        e.StartingOffset.QuadPart = p.offset
        e.PartitionLength.QuadPart = p.size
        e.PartitionNumber = i
        e.RewritePartition = 1
        
        if scheme == "GPT" then
            e.Gpt.PartitionType = util.guid_from_str(p.gpt_type)
            ole32.CoCreateGuid(e.Gpt.PartitionId)
            local wn = util.to_wide(p.name)
            ffi.copy(e.Gpt.Name, wn, math.min(72, ffi.sizeof(wn)))
        else
            e.Mbr.PartitionType = p.mbr_type
            e.Mbr.BootIndicator = 0
        end
    end
    
    return set_layout(drive, layout)
end

return M