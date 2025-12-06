local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local layout = require 'win-utils.disk.layout'
local physical = require 'win-utils.disk.physical'
local types = require 'win-utils.disk.types'
local reg = require 'win-utils.reg.init'

local M = {}
local REG_KEY = "Software\\LuaWinUtils\\EspToggle"

local function guid_eq(a, b) return ffi.string(a, 16) == ffi.string(b, 16) end

function M.toggle(drive_idx, offset)
    local drive, err = physical.open(drive_idx, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local locked, lock_err = drive:lock(true)
    if not locked then 
        drive:close()
        return false, "Lock failed: " .. tostring(lock_err) 
    end
    
    local info, layout_err = layout.get(drive)
    if not info then 
        drive:close()
        return false, "GetLayout failed: " .. tostring(layout_err) 
    end
    
    local p = nil
    for _, part in ipairs(info.parts) do
        if part.off == offset then p = part; break end
    end
    
    if not p then drive:close(); return false, "Partition not found" end
    
    local changed = false
    local new_type_id
    
    if info.style == "GPT" then
        local esp = util.guid_from_str(types.GPT.ESP)
        local data = util.guid_from_str(types.GPT.DATA)
        
        if guid_eq(util.guid_from_str(p.type), esp) then
            new_type_id = types.GPT.DATA
            changed = true
            -- Save state (simplified)
            local k = reg.open_key("HKCU", REG_KEY) 
            if k then k:write(tostring(offset), "ESP"); k:close() end
        else
            new_type_id = types.GPT.ESP
            changed = true
        end
    else
        if p.type == types.MBR.ESP then
            new_type_id = types.MBR.FAT32
            changed = true
        else
            new_type_id = types.MBR.ESP
            changed = true
        end
    end
    
    local res = false
    local msg
    
    if changed then
        local parts = info.parts
        for _, part in ipairs(parts) do
            if part.off == offset then part.type = new_type_id end
        end
        local ok, apply_err = layout.apply(drive, info.style, parts)
        if ok then res = true
        else msg = apply_err end
    else
        res = true; msg = "No change needed"
    end
    
    drive:close()
    return res, msg
end

return M