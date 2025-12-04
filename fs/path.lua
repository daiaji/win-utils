local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local M = {}

local dos_map = nil
function M.nt_path_to_dos(nt)
    if not dos_map then
        dos_map = {}
        local buf = ffi.new("wchar_t[512]")
        for i=65,90 do
            local drv = string.char(i)..":"
            if kernel32.QueryDosDeviceW(util.to_wide(drv), buf, 512) > 0 then
                local t = util.from_wide(buf)
                if t then dos_map[t] = drv end
            end
        end
    end
    if not nt then return nil end
    for k,v in pairs(dos_map) do
        if nt:find(k, 1, true) == 1 then return v .. nt:sub(#k+1) end
    end
    return nt
end
return M