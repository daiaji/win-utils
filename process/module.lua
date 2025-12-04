local ffi = require 'ffi'
local psapi = require 'ffi.req' 'Windows.sdk.psapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

function M.list(pid)
    local h = kernel32.OpenProcess(0x410, false, pid)
    if not h then return {} end
    local mods = ffi.new("HMODULE[1024]")
    local cb = ffi.new("DWORD[1]")
    local res = {}
    if psapi.EnumProcessModulesEx(h, mods, ffi.sizeof(mods), cb, 3) ~= 0 then
        local count = cb[0] / ffi.sizeof("HMODULE")
        local buf = ffi.new("wchar_t[1024]")
        for i=0, count-1 do
            if psapi.GetModuleFileNameExW(h, mods[i], buf, 1024) > 0 then
                table.insert(res, util.from_wide(buf))
            end
        end
    end
    kernel32.CloseHandle(h)
    return res
end

return M