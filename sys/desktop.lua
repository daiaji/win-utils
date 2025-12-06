local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local M = {}

function M.set_wallpaper(p) 
    if user32.SystemParametersInfoW(20, 0, ffi.cast("void*", util.to_wide(p)), 3) == 0 then
        return false, util.last_error()
    end
    return true
end

function M.refresh()
    shell32.SHChangeNotify(0x8000000, 0, nil, nil)
end

return M