local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'

local M = {}
local anchors = {} -- 防止回调被 GC

-- [Restore] Complete implementation with callbacks and safety
function M.reg(id, modifiers, key, cb)
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
    
    if user32.RegisterHotKey(nil, id, mod_flag, vk) == 0 then return false end
    anchors[id] = cb
    return true
end

function M.unreg(id)
    anchors[id] = nil
    return user32.UnregisterHotKey(nil, id) ~= 0
end

-- [Restore] Safe Dispatcher
function M.dispatch(id)
    local cb = anchors[id]
    if cb then
        xpcall(cb, debug.traceback)
    end
end

return M