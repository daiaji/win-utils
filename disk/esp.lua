local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local winioctl = require 'ffi.req' 'Windows.sdk.winioctl'
local util = require 'win-utils.util'
local types = require 'win-utils.disk.types'
local layout_lib = require 'win-utils.disk.layout'
local registry = require 'win-utils.registry'

local M = {}
local C = ffi.C

-- Config Key for storing ESP state
local REG_ROOT = "HKCU"
local REG_KEY = "Software\\LuaWinUtils\\EspToggle"

-- Compare two GUID cdata
local function guid_equal(g1, g2)
    return ffi.string(g1, ffi.sizeof("GUID")) == ffi.string(g2, ffi.sizeof("GUID"))
end

local function get_guid_str(guid_cdata)
    local g = guid_cdata
    return string.format("{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        g.Data1, g.Data2, g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7])
end

-- Persist original GUID to registry so we can restore it exactly later
local function store_esp_info(guid_str)
    local key = registry.open_key(REG_ROOT, REG_KEY)
    if not key then
        -- Try creating key
        local advapi = require('ffi.req')('Windows.sdk.advapi32')
        local hKey = ffi.new("HKEY[1]")
        if advapi.RegCreateKeyExW(ffi.cast("HKEY", 0x80000001), util.to_wide(REG_KEY), 0, nil, 0, 0xF003F, nil, hKey, nil) == 0 then
            advapi.RegCloseKey(hKey[0])
            key = registry.open_key(REG_ROOT, REG_KEY)
        end
    end
    
    if key then
        -- Find empty slot or shift
        for i = 1, 8 do
            local val = key:read("ToggleEsp" .. string.format("%02d", i))
            if not val or val == "" then
                key:write("ToggleEsp" .. string.format("%02d", i), guid_str)
                key:close()
                return true
            end
        end
        -- Rotate
        for i = 1, 7 do
            local next_val = key:read("ToggleEsp" .. string.format("%02d", i+1))
            key:write("ToggleEsp" .. string.format("%02d", i), next_val or "")
        end
        key:write("ToggleEsp08", guid_str)
        key:close()
        return true
    end
    return false
end

local function get_stored_guid(index)
    local key = registry.open_key(REG_ROOT, REG_KEY)
    if not key then return nil end
    local val = key:read("ToggleEsp" .. string.format("%02d", index))
    key:close()
    if val and val ~= "" then return util.guid_from_str(val) end
    return nil
end

local function clear_esp_info(guid_str)
    local key = registry.open_key(REG_ROOT, REG_KEY)
    if not key then return end
    
    -- Find and clear specific GUID
    for i = 1, 8 do
        local val = key:read("ToggleEsp" .. string.format("%02d", i))
        if val == guid_str then
            key:write("ToggleEsp" .. string.format("%02d", i), "")
            break
        end
    end
    key:close()
end

-- Port of ToggleEsp from Rufus drive.c
-- Returns: success, message
function M.toggle(drive, partition_offset)
    local layout = layout_lib.get_raw_layout(drive)
    if not layout then return false, "Could not get drive layout" end

    local target_idx = -1
    -- Find partition by offset
    for i = 0, layout.PartitionCount - 1 do
        if tonumber(layout.PartitionEntry[i].StartingOffset.QuadPart) == partition_offset then
            target_idx = i
            break
        end
    end
    
    -- If offset is 0, auto-detect ESP
    if partition_offset == 0 and target_idx == -1 then
        for i = 0, layout.PartitionCount - 1 do
            local entry = layout.PartitionEntry[i]
            if layout.PartitionStyle == C.PARTITION_STYLE_GPT then
                if guid_equal(entry.Gpt.PartitionType, util.guid_from_str(types.GPT.ESP)) then
                    target_idx = i
                    break
                end
            elseif layout.PartitionStyle == C.PARTITION_STYLE_MBR then
                if entry.Mbr.PartitionType == types.MBR.ESP then
                    target_idx = i
                    break
                end
            end
        end
    end

    if target_idx == -1 then return false, "Partition not found" end

    local entry = layout.PartitionEntry[target_idx]
    local changed = false
    local new_type_name = ""
    local is_revert = false

    if layout.PartitionStyle == C.PARTITION_STYLE_GPT then
        local current_type = entry.Gpt.PartitionType
        local esp_guid = util.guid_from_str(types.GPT.ESP)
        local data_guid = util.guid_from_str(types.GPT.BASIC_DATA)
        local current_guid_str = get_guid_str(entry.Gpt.PartitionId)

        if guid_equal(current_type, esp_guid) then
            -- ESP -> Data (Hide it)
            store_esp_info(current_guid_str)
            entry.Gpt.PartitionType = data_guid
            new_type_name = "Basic Data"
            changed = true
        elseif guid_equal(current_type, data_guid) then
            -- Data -> ESP (Restore it?)
            -- Check registry to see if we hid this specific partition
            -- Rufus logic: check if this partition ID is in our list
            -- For simplicity here: if user asks to toggle a Data partition, we assume they want it to be ESP
            -- Ideally we check registry
            
            entry.Gpt.PartitionType = esp_guid
            new_type_name = "ESP"
            changed = true
            is_revert = true
            clear_esp_info(current_guid_str)
        else
            return false, "Partition is neither ESP nor Basic Data"
        end
    elseif layout.PartitionStyle == C.PARTITION_STYLE_MBR then
        if entry.Mbr.PartitionType == types.MBR.ESP then
            entry.Mbr.PartitionType = types.MBR.FAT32 -- Default fallback
            new_type_name = "FAT32"
            changed = true
        elseif entry.Mbr.PartitionType == types.MBR.FAT32 or entry.Mbr.PartitionType == types.MBR.FAT32_LBA then
            entry.Mbr.PartitionType = types.MBR.ESP
            new_type_name = "ESP (0xEF)"
            changed = true
        else
            return false, "Partition type not toggleable (MBR)"
        end
    else
        return false, "Unsupported partition style"
    end

    if changed then
        entry.RewritePartition = 1
        local size = ffi.sizeof("DRIVE_LAYOUT_INFORMATION_EX_FULL")
        local bytes = ffi.new("DWORD[1]")
        
        if kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, 
            layout, size, nil, 0, bytes, nil) == 0 then
            return false, "SetLayout failed: " .. util.format_error()
        end
        
        kernel32.DeviceIoControl(drive.handle, C.IOCTL_DISK_UPDATE_PROPERTIES, nil, 0, nil, 0, bytes, nil)
        return true, new_type_name
    end

    return false, "No change needed"
end

return M