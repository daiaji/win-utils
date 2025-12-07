local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'

local M = {}
local anchors = {} 

-- [RESTORED] Auto ID generation support
-- reg(modifiers, key, cb) OR reg(id, modifiers, key, cb)
function M.reg(id_or_mod, mod_or_key, key_or_cb, cb_or_nil)
    local id, modifiers, key, cb
    
    -- Overload resolution
    if type(id_or_mod) == "number" then
        id, modifiers, key, cb = id_or_mod, mod_or_key, key_or_cb, cb_or_nil
    else
        -- Auto-allocate ID (Range 1 to 0xBFFF)
        local free_id = 1
        while anchors[free_id] do free_id = free_id + 1 end
        if free_id > 0xBFFF then return false, "No free hotkey IDs" end
        id = free_id
        
        modifiers, key, cb = id_or_mod, mod_or_key, key_or_cb
    end

    if not cb or type(cb) ~= "function" then return false, "Callback required" end
    
    local mod_flag = 0
    if type(modifiers) == "string" then
        local s = modifiers:lower()
        if s:find("alt") then mod_flag = bit.bor(mod_flag, 1) end
        if s:find("ctrl") then mod_flag = bit.bor(mod_flag, 2) end
        if s:find("shift") then mod_flag = bit.bor(mod_flag, 4) end
        if s:find("win") then mod_flag = bit.bor(mod_flag, 8) end
    else
        mod_flag = modifiers or 0
    end
    
    local vk = key
    if type(key) == "string" and #key == 1 then
        vk = bit.band(user32.VkKeyScanW(string.byte(key:upper())), 0xFF)
    end
    
    if user32.RegisterHotKey(nil, id, mod_flag, vk) == 0 then 
        return false, util.last_error("RegisterHotKey failed")
    end
    anchors[id] = cb
    return id -- Return the allocated ID
end

function M.unreg(id)
    anchors[id] = nil
    if user32.UnregisterHotKey(nil, id) == 0 then
        return false, util.last_error("UnregisterHotKey failed")
    end
    return true
end

function M.clear()
    for id, _ in pairs(anchors) do
        user32.UnregisterHotKey(nil, id)
    end
    anchors = {}
    return true
end

function M.dispatch(id)
    local cb = anchors[id]
    if cb then xpcall(cb, debug.traceback) end
end

return M