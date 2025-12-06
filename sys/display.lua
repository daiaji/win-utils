local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local ccd = require 'ffi.req' 'Windows.sdk.ccd'
local bit = require 'bit'
local util = require 'win-utils.core.util'
local M = {}

function M.set_res(w,h,hz)
    local dm = ffi.new("DEVMODEW"); dm.dmSize = ffi.sizeof(dm)
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x180000
    if hz then dm.dmDisplayFrequency = hz; dm.dmFields = bit.bor(dm.dmFields, 0x400000) end
    
    local res = user32.ChangeDisplaySettingsExW(nil, dm, nil, 0, nil)
    if res ~= 0 then return false, "ChangeDisplaySettings failed code: " .. res end
    return true
end

function M.set_topology(mode)
    local f = 0x80 -- APPLY
    if mode=="clone" then f=bit.bor(f,2)
    elseif mode=="extend" then f=bit.bor(f,4)
    elseif mode=="external" then f=bit.bor(f,8)
    else f=bit.bor(f,1) end -- internal
    
    local res = ccd.SetDisplayConfig(0, nil, 0, nil, f)
    if res ~= 0 then return false, "SetDisplayConfig failed code: " .. res end
    return true
end

return M