local ffi = require 'ffi'
local bit = require 'bit'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.util'
local types = require 'win-utils.disk.types'

local M = {}
local C = ffi.C

-- Alignment constants
local ONE_MB = 1024 * 1024
local DEFAULT_ESP_SIZE = 260 * ONE_MB
local DEFAULT_MSR_SIZE = 128 * ONE_MB

-- [NEW] Helper to check/set 64-bit flags
-- Lua 5.1/BitOp operates on 32-bit. We need to split the 64-bit attribute.
-- We only support the standard GPT flags which fit in low/high parts.
local function check_gpt_attr(attr_u64, flag_u64)
    -- This is a simplified check. Real 64-bit bitwise in LuaJIT requires casting.
    -- attr_u64 is cdata<uint64_t>.
    local res = bit.band(attr_u64, flag_u64)
    return res ~= 0
end

function M.align_up(val, alignment)
    if alignment == 0 then return val end
    return math.ceil(val / alignment) * alignment
end

function M.align_down(val, alignment)
    if alignment == 0 then return val end
    return math.floor(val / alignment) * alignment
end

function M.get_raw_layout(drive)
    local layout = ffi.new("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local bytes = ffi.new("DWORD[1]")
    
    local res = kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 
        nil, 0, layout, ffi.sizeof(layout), bytes, nil)
        
    if res == 0 then return nil, util.format_error() end
    return layout
end

function M.get_info(drive)
    local layout = M.get_raw_layout(drive)
    if not layout then return nil, "Failed to retrieve layout" end

    local info = {
        style = (layout.PartitionStyle == C.PARTITION_STYLE_MBR) and "MBR" or "GPT",
        count = layout.PartitionCount,
        partitions = {}
    }

    if info.style == "MBR" then
        info.signature = layout.Mbr.Signature
    else
        info.disk_id = layout.Gpt.DiskId
    end

    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        -- Filter empty MBR slots
        if not (info.style == "MBR" and p.Mbr.PartitionType == 0) then
            local part = {
                number = p.PartitionNumber,
                index = i + 1,
                offset = tonumber(p.StartingOffset.QuadPart),
                length = tonumber(p.PartitionLength.QuadPart),
            }
            
            if info.style == "MBR" then
                part.type = p.Mbr.PartitionType
                part.active = (p.Mbr.BootIndicator ~= 0)
                part.hidden = p.Mbr.HiddenSectors
            else
                part.type_guid = p.Gpt.PartitionType
                part.id_guid = p.Gpt.PartitionId
                part.attributes = p.Gpt.Attributes -- Keep as cdata<uint64>
                part.name = util.from_wide(p.Gpt.Name)
            end
            table.insert(info.partitions, part)
        end
    end
    return info
end

function M.set_active(drive, partition_index, active)
    local layout = M.get_raw_layout(drive)
    if not layout then return false, "Could not read layout" end
    
    if layout.PartitionStyle ~= C.PARTITION_STYLE_MBR then
        return false, "Setting active partition is only supported on MBR disks"
    end
    
    local found = false
    for i = 0, layout.PartitionCount - 1 do
        local p = layout.PartitionEntry[i]
        if p.Mbr.PartitionType ~= 0 then
            if active then p.Mbr.BootIndicator = 0 end
            
            if p.PartitionNumber == partition_index then
                p.Mbr.BootIndicator = active and 0x80 or 0
                p.RewritePartition = 1
                found = true
            end
        end
    end
    
    if not found then return false, "Partition index not found" end
    
    local size = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, 
        layout, size, nil, 0, bytes, nil) == 0 then
        return false, "SetLayout Failed: " .. util.format_error()
    end
    
    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
    return true
end

function M.set_partition_type(drive, part_index, type_id)
    local layout = M.get_raw_layout(drive)
    if not layout then return false, "Could not read layout" end
    
    local entry = nil
    for i = 0, layout.PartitionCount - 1 do
        if layout.PartitionEntry[i].PartitionNumber == part_index then
            entry = layout.PartitionEntry[i]
            break
        end
    end
    
    if not entry then return false, "Partition index not found" end
    
    if layout.PartitionStyle == C.PARTITION_STYLE_GPT then
        if type(type_id) ~= "string" then return false, "GPT requires GUID string for type" end
        entry.Gpt.PartitionType = util.guid_from_str(type_id)
    elseif layout.PartitionStyle == C.PARTITION_STYLE_MBR then
        if type(type_id) ~= "number" then return false, "MBR requires byte number for type" end
        entry.Mbr.PartitionType = type_id
    else
        return false, "Unsupported partition style"
    end
    
    entry.RewritePartition = 1
    
    local size = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, 
        layout, size, nil, 0, bytes, nil) == 0 then
        return false, "SetLayout Failed: " .. util.format_error()
    end
    
    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
    return true
end

-- Set Partition Attributes (GPT Only)
-- @param attributes: number or cdata<uint64>
function M.set_partition_attributes(drive, part_index, attributes)
    local layout = M.get_raw_layout(drive)
    if not layout then return false, "Could not read layout" end
    
    if layout.PartitionStyle ~= C.PARTITION_STYLE_GPT then
        return false, "Setting attributes is only supported on GPT disks"
    end
    
    local found = false
    for i = 0, layout.PartitionCount - 1 do
        if layout.PartitionEntry[i].PartitionNumber == part_index then
            layout.PartitionEntry[i].Gpt.Attributes = attributes
            layout.PartitionEntry[i].RewritePartition = 1
            found = true
            break
        end
    end
    
    if not found then return false, "Partition index not found" end
    
    local size = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, 
        layout, size, nil, 0, bytes, nil) == 0 then
        return false, "SetLayout Failed: " .. util.format_error()
    end
    
    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
    return true
end

function M.clean(drive)
    local create = ffi.new("CREATE_DISK")
    create.PartitionStyle = C.PARTITION_STYLE_RAW 
    local bytes = ffi.new("DWORD[1]")
    
    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_CREATE_DISK, 
        create, ffi.sizeof(create), nil, 0, bytes, nil) == 0 then
        return false, util.format_error()
    end
    
    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
    return true
end

function M.calculate_partition_plan(drive, scheme_type, opts)
    opts = opts or {}
    local partitions = {}
    local sector_size = drive.sector_size
    local disk_size = drive.size
    local align_size = ONE_MB
    local cluster_size = opts.cluster_size -- [FIX] Added cluster_size option
    
    local gpt_footer_size = 33 * sector_size
    local usable_end = disk_size
    if scheme_type == "GPT" then
        usable_end = disk_size - gpt_footer_size
    end

    local current_offset = align_size 

    if scheme_type == "GPT" and opts.create_msr then
        local msr_size = DEFAULT_MSR_SIZE
        table.insert(partitions, {
            type = "MSR",
            offset = current_offset,
            size = M.align_up(msr_size, sector_size),
            gpt_type = types.GPT.MSR,
            name = "Microsoft Reserved Partition"
        })
        current_offset = current_offset + msr_size
        current_offset = M.align_up(current_offset, align_size)
    end

    if opts.create_esp then
        local esp_size = DEFAULT_ESP_SIZE
        table.insert(partitions, {
            type = "ESP",
            offset = current_offset,
            size = M.align_up(esp_size, sector_size),
            gpt_type = types.GPT.ESP,
            mbr_type = types.MBR.ESP,
            name = "EFI System Partition"
        })
        current_offset = current_offset + esp_size
        current_offset = M.align_up(current_offset, align_size)
    end

    local remaining = usable_end - current_offset
    remaining = M.align_down(remaining, align_size)
    
    if remaining > 0 then
        -- [FIX] Align Data Partition size to cluster size (Large FAT32 compatibility)
        -- See Rufus format.c: CreatePartition
        if cluster_size and cluster_size > 0 then
            remaining = M.align_down(remaining, cluster_size)
        end

        table.insert(partitions, {
            type = "DATA",
            offset = current_offset,
            size = remaining,
            gpt_type = types.GPT.BASIC_DATA,
            mbr_type = types.MBR.NTFS, 
            name = "Basic Data Partition"
        })
    end

    return partitions
end

function M.apply_partition_plan(drive, scheme_type, partitions)
    local layout = ffi.new("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local size = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
    local bytes = ffi.new("DWORD[1]")

    local create = ffi.new("CREATE_DISK")
    if scheme_type == "GPT" then
        create.PartitionStyle = C.PARTITION_STYLE_GPT
        ole32.CoCreateGuid(create.Gpt.DiskId)
        create.Gpt.MaxPartitionCount = 128
    else
        create.PartitionStyle = C.PARTITION_STYLE_MBR
        create.Mbr.Signature = os.time()
    end

    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_CREATE_DISK, 
        create, ffi.sizeof(create), nil, 0, bytes, nil) == 0 then
        return false, "Initialize Disk Failed: " .. util.format_error()
    end
    
    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)

    if scheme_type == "GPT" then
        layout.PartitionStyle = C.PARTITION_STYLE_GPT
        layout.PartitionCount = #partitions
        layout.Gpt.DiskId = create.Gpt.DiskId
        layout.Gpt.MaxPartitionCount = 128
        layout.Gpt.StartingUsableOffset.QuadPart = 34 * drive.sector_size
        layout.Gpt.UsableLength.QuadPart = drive.size - (67 * drive.sector_size) 
    else
        layout.PartitionStyle = C.PARTITION_STYLE_MBR
        layout.PartitionCount = #partitions
        layout.Mbr.Signature = create.Mbr.Signature
    end

    for i, p in ipairs(partitions) do
        local entry = layout.PartitionEntry[i-1]
        entry.PartitionStyle = layout.PartitionStyle
        entry.StartingOffset.QuadPart = p.offset
        entry.PartitionLength.QuadPart = p.size
        entry.PartitionNumber = i
        entry.RewritePartition = 1
        
        if scheme_type == "GPT" then
            local guid_struct = util.guid_from_str(p.gpt_type)
            entry.Gpt.PartitionType = guid_struct
            ole32.CoCreateGuid(entry.Gpt.PartitionId)
            
            local name_w = util.to_wide(p.name)
            ffi.copy(entry.Gpt.Name, name_w, math.min(72, ffi.sizeof(name_w)))
        else
            entry.Mbr.PartitionType = p.mbr_type
            entry.Mbr.BootIndicator = 0 
        end
    end

    if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, 
        layout, size, nil, 0, bytes, nil) == 0 then
        return false, "SetLayout Failed: " .. util.format_error()
    end

    kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)

    -- [FIX] Partition Clearing (Robustness)
    -- Wipes the first few sectors of new partitions to prevent Windows from seeing ghost filesystems.
    -- Rufus matches this logic in format.c (ClearPartition)
    local wipe_bytes = 8 * 1024 * 1024 -- 8MB (Rufus MAX_SECTORS_TO_CLEAR * 512)
    local zero_buf = kernel32.VirtualAlloc(nil, wipe_bytes, 0x1000, 0x04)
    
    if zero_buf ~= nil then
        for _, p in ipairs(partitions) do
            local wipe_size = math.min(wipe_bytes, p.size)
            -- Align to sector size
            wipe_size = math.floor(wipe_size / drive.sector_size) * drive.sector_size
            
            local li = ffi.new("LARGE_INTEGER")
            li.QuadPart = p.offset
            
            if kernel32.SetFilePointerEx(drive.handle, li, nil, C.FILE_BEGIN) ~= 0 then
                local written = ffi.new("DWORD[1]")
                -- We ignore write errors here to avoid failing the whole process for non-critical cleaning
                kernel32.WriteFile(drive.handle, zero_buf, wipe_size, written, nil)
            end
        end
        kernel32.VirtualFree(zero_buf, 0, 0x8000)
    end

    return true
end

return M