local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local bit = require 'bit'

local M = {}
local anchors = {}

function M.register(mod, key, cb)
    local id = 1; while anchors[id] do id = id + 1 end
    local mf = 0
    if mod:find("Alt") then mf=bit.bor(mf,1) end
    if mod:find("Ctrl") then mf=bit.bor(mf,2) end
    if mod:find("Shift") then mf=bit.bor(mf,4) end
    if mod:find("Win") then mf=bit.bor(mf,8) end
    
    local vk = type(key)=="string" and bit.band(user32.VkKeyScanW(string.byte(key)), 0xFF) or key
    if user32.RegisterHotKey(nil, id, mf, vk) == 0 then return nil end
    anchors[id] = cb
    return id
end

function M.unregister(id)
    anchors[id] = nil
    return user32.UnregisterHotKey(nil, id) ~= 0
end

function M.dispatch(id)
    if anchors[id] then anchors[id]() end
end

function M.clear()
    for id, _ in pairs(anchors) do
        user32.UnregisterHotKey(nil, id)
    end
    anchors = {}
end

return M