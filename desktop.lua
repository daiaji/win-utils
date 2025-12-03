local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.util'
local registry = require 'win-utils.registry'

local M = {}

function M.refresh()
    -- SHChangeNotify is in Shell32, user32 defs might miss it. Safe to dynamic load.
    local sh = ffi.load("shell32")
    if sh then sh.SHChangeNotify(0x08000000, 0, nil, nil) end
end

function M.set_wallpaper(path, style)
    local key = registry.open_key("HKCU", "Control Panel\\Desktop")
    if key then
        local s, t = "10", "0"
        if style=="fit" then s="6" elseif style=="stretch" then s="2" elseif style=="tile" then s="0";t="1" end
        key:write("WallpaperStyle", s); key:write("TileWallpaper", t); key:close()
    end
    return user32.SystemParametersInfoW(0x0014, 0, ffi.cast("void*", util.to_wide(path)), 3) ~= 0
end

return M