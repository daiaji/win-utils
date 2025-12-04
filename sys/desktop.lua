local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'
local M = {}

function M.set_wallpaper(p) user32.SystemParametersInfoW(20, 0, ffi.cast("void*", util.to_wide(p)), 3) end

function M.refresh()
    local sh = ffi.load("shell32")
    if sh then sh.SHChangeNotify(0x8000000, 0, nil, nil) end
end

return M