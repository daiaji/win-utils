local ffi = require 'ffi'
local util = require 'win-utils.util'
local layout = require 'win-utils.disk.layout'
local physical = require 'win-utils.disk.physical'
local types = require 'win-utils.disk.types'
local registry = require 'win-utils.registry'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'

local M = {}

-- 注册表配置路径
local REG_KEY = "Software\\LuaWinUtils\\EspToggle"

-- 比较 GUID cdata
local function guid_eq(a, b)
    return ffi.string(a, ffi.sizeof("GUID")) == ffi.string(b, ffi.sizeof("GUID"))
end

local function get_guid_str(g)
    return string.format("{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        g.Data1, g.Data2, g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7])
end

-- 辅助：打开或创建注册表键
local function open_or_create_config_key()
    local key = registry.open_key("HKCU", REG_KEY)
    if key then return key end
    
    local hKey = ffi.new("HKEY[1]")
    -- HKCU = 0x80000001, KEY_ALL_ACCESS = 0xF003F
    if advapi32.RegCreateKeyExW(ffi.cast("HKEY", 0x80000001), util.to_wide(REG_KEY), 0, nil, 0, 0xF003F, nil, hKey, nil) == 0 then
        -- 使用内部构造函数封装 Handle
        return registry.open_key("HKCU", REG_KEY) 
    end
    return nil
end

-- 保存 ESP 的原始 GUID
local function store_esp_info(guid_str)
    local key = open_or_create_config_key()
    if not key then return end
    
    -- 查找空槽位或轮转
    local slot = nil
    for i = 1, 8 do
        local name = string.format("ToggleEsp%02d", i)
        local val = key:read(name)
        if not val or val == "" then
            slot = name
            break
        end
    end
    
    if not slot then
        -- 轮转：移除第一个，后移
        for i = 1, 7 do
            local next_val = key:read(string.format("ToggleEsp%02d", i+1))
            key:write(string.format("ToggleEsp%02d", i), next_val or "")
        end
        slot = "ToggleEsp08"
    end
    
    key:write(slot, guid_str)
    key:close()
end

-- 清除已恢复的 ESP 记录
local function clear_esp_info(guid_str)
    local key = registry.open_key("HKCU", REG_KEY)
    if not key then return end
    
    for i = 1, 8 do
        local name = string.format("ToggleEsp%02d", i)
        local val = key:read(name)
        if val == guid_str then
            key:write(name, "") -- Clear
            break
        end
    end
    key:close()
end

function M.toggle(drive_idx, offset)
    local drive = physical.open(drive_idx, true, true)
    if not drive then return false, "Open failed" end
    if not drive:lock(true) then drive:close(); return false, "Lock failed" end
    
    local info = layout.get_info(drive)
    if not info then drive:close(); return false, "Info failed" end
    
    local p = nil
    for _, part in ipairs(info.partitions) do
        if part.offset == offset then p = part; break end
    end
    
    if not p then drive:close(); return false, "Partition not found" end
    
    local changed = false
    local type_name = ""
    local new_type_id
    local attrs = nil
    
    if info.style == "GPT" then
        local esp = util.guid_from_str(types.GPT.ESP)
        local data = util.guid_from_str(types.GPT.BASIC_DATA)
        local current_id_str = get_guid_str(p.id)
        
        if guid_eq(p.type_guid, esp) then
            -- ESP -> Data (Hide)
            store_esp_info(current_id_str)
            new_type_id = types.GPT.BASIC_DATA
            type_name = "Basic Data"
            -- Remove SYSTEM attribute if present? Usually implies removing 0x....
            -- But strictly we just change Type GUID.
            changed = true
        elseif guid_eq(p.type_guid, data) then
            -- Data -> ESP (Restore)
            clear_esp_info(current_id_str)
            new_type_id = types.GPT.ESP
            type_name = "ESP"
            changed = true
        else
            drive:close()
            return false, "Partition is neither ESP nor Basic Data"
        end
    else
        -- MBR
        if p.type == types.MBR.ESP then
            new_type_id = types.MBR.FAT32
            type_name = "FAT32"
            changed = true
        elseif p.type == types.MBR.FAT32 or p.type == types.MBR.FAT32_LBA then
            new_type_id = types.MBR.ESP
            type_name = "ESP"
            changed = true
        else
            drive:close()
            return false, "Unsupported MBR partition type"
        end
    end
    
    local res = false
    local err = nil
    
    if changed then
        res, err = layout.set_partition_type(drive, p.number, new_type_id)
    else
        res = false
        err = "No change needed"
    end
    
    drive:close()
    return res, changed and type_name or err
end

return M