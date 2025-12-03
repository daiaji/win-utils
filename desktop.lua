local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local registry = require 'win-utils.registry'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- 刷新 Shell (重建图标缓存，通知 Explorer 配置已更改)
function M.refresh_shell()
    -- SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0
    -- user32.lua 中定义为 SHChangeNotify(LONG, UINT, LPCVOID, LPCVOID)
    -- 此处绑定可能在 shell32.lua，但在前面的 update 中我们加到了 user32.lua (虽然它在 shell32.dll)
    -- 注意：SHChangeNotify 实际上在 shell32.dll。
    -- 如果之前的 user32.lua 定义有误，这里需要显式 load shell32。
    -- 修正：SHChangeNotify 在 Shell32.dll。
    
    local shell32 = ffi.load("shell32")
    if shell32 then
        shell32.SHChangeNotify(0x08000000, 0, nil, nil)
    end
end

-- 设置壁纸 (模拟 Windows 行为，修改注册表后调用 SPI)
-- style: "fill", "fit", "stretch", "tile", "center", "span"
function M.set_wallpaper(path, style)
    local key = registry.open_key("HKCU", "Control Panel\\Desktop")
    if not key then return false, "Cannot open Registry" end
    
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
    
    -- Apply immediately via SystemParametersInfo
    -- SPI_SETDESKWALLPAPER (20), SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE (3)
    local wpath = util.to_wide(path)
    if user32.SystemParametersInfoW(0x0014, 0, ffi.cast("void*", wpath), 3) == 0 then
        return false, util.format_error()
    end
    
    return true
end

return M