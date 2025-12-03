local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local ccd = require 'ffi.req' 'Windows.sdk.ccd'
local bit = require 'bit'

local M = {}

function M.set_topology(mode)
    local flags = 0x80 -- APPLY
    if mode=="clone" then flags=bit.bor(flags, 2)
    elseif mode=="extend" then flags=bit.bor(flags, 4)
    elseif mode=="external" then flags=bit.bor(flags, 8)
    else flags=bit.bor(flags, 1) end -- internal
    return ccd.SetDisplayConfig(0, nil, 0, nil, flags) == 0
end

function M.set_resolution(w, h, hz)
    local dm = ffi.new("DEVMODEW"); dm.dmSize = ffi.sizeof(dm)
    if user32.EnumDisplaySettingsW(nil, -1, dm) == 0 then return false end
    
    dm.dmPelsWidth = w; dm.dmPelsHeight = h
    dm.dmFields = 0x180000 -- WIDTH|HEIGHT
    if hz then dm.dmDisplayFrequency = hz; dm.dmFields = bit.bor(dm.dmFields, 0x400000) end
    
    return user32.ChangeDisplaySettingsExW(nil, dm, nil, 1, nil) == 0
end

return M