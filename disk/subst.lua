local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.util'

local M = {}

local function notify()
    user32.PostMessageW(ffi.cast("HWND", 0xFFFF), 0x001A, 0, ffi.cast("LPARAM", util.to_wide("Environment")))
end

function M.mount(drive, path)
    if kernel32.DefineDosDeviceW(0, util.to_wide(drive), util.to_wide(path)) == 0 then return false, util.format_error() end
    notify()
    return true
end

function M.unmount(drive)
    if kernel32.DefineDosDeviceW(2, util.to_wide(drive), nil) == 0 then return false, util.format_error() end
    notify()
    return true
end

function M.query(drive)
    local buf = ffi.new("wchar_t[1024]")
    if kernel32.QueryDosDeviceW(util.to_wide(drive), buf, 1024) == 0 then return nil end
    local target = util.from_wide(buf)
    return target:match("^%\\%?%?\\") and target:sub(5) or target
end

return M