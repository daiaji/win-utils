local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local M = {}

function M.burn_dd(img, drive, cb)
    local f = native.open_file(img, "r")
    if not f then return false end
    local buf = kernel32.VirtualAlloc(nil, 1024*1024, 0x1000, 4)
    local r = ffi.new("DWORD[1]")
    local pos = 0
    local size = ffi.new("LARGE_INTEGER"); kernel32.GetFileSizeEx(f:get(), size)
    local total = tonumber(size.QuadPart)
    
    local ok = true
    while pos < total do
        if kernel32.ReadFile(f:get(), buf, 1024*1024, r, nil) == 0 then ok=false; break end
        if r[0] == 0 then break end
        if not drive:write_sectors(pos, ffi.string(buf, r[0])) then ok=false; break end -- Need impl in physical
        pos = pos + r[0]
        if cb then cb(pos/total) end
    end
    kernel32.VirtualFree(buf, 0, 0x8000)
    f:close()
    return ok
end
return M