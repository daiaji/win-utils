local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'
local M = {}

-- [RESTORED] 设置壁纸及样式
-- style: "fill", "fit", "stretch", "tile", "center", "span"
function M.set_wallpaper(path, style) 
    -- 1. 更新注册表样式
    local key = reg.open_key("HKCU", "Control Panel\\Desktop")
    if key then
        local wp_style = "10" -- Fill (Default)
        local tile_wp = "0"
        
        if style == "fit" then wp_style = "6"; tile_wp = "0"
        elseif style == "stretch" then wp_style = "2"; tile_wp = "0"
        elseif style == "tile" then wp_style = "0"; tile_wp = "1"
        elseif style == "center" then wp_style = "0"; tile_wp = "0"
        elseif style == "span" then wp_style = "22"; tile_wp = "0"
        end
        
        key:write("WallpaperStyle", wp_style)
        key:write("TileWallpaper", tile_wp)
        key:close()
    end

    -- 2. 应用壁纸
    -- SPI_SETDESKWALLPAPER (20), SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE (3)
    if user32.SystemParametersInfoW(20, 0, ffi.cast("void*", util.to_wide(path)), 3) == 0 then
        return false, util.last_error()
    end
    return true
end

function M.refresh()
    shell32.SHChangeNotify(0x8000000, 0, nil, nil)
end

return M