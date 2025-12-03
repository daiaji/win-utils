local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local psapi = require 'ffi.req' 'Windows.sdk.psapi'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}

function M.list(pid)
    -- PROCESS_QUERY_INFORMATION(0x400) | PROCESS_VM_READ(0x10)
    local hProc = kernel32.OpenProcess(0x410, false, pid)
    if not hProc then return nil end
    local procGuard = Handle.new(hProc)
    
    local mods = ffi.new("HMODULE[1024]")
    local cb = ffi.new("DWORD[1]")
    
    -- LIST_MODULES_ALL = 0x03
    if psapi.EnumProcessModulesEx(hProc, mods, ffi.sizeof(mods), cb, 0x03) == 0 then 
        return nil 
    end
    
    local res = {}
    local buf = ffi.new("wchar_t[1024]")
    local count = cb[0] / ffi.sizeof("HMODULE")
    
    for i = 0, count - 1 do
        if psapi.GetModuleFileNameExW(hProc, mods[i], buf, 1024) > 0 then
            table.insert(res, util.from_wide(buf))
        end
    end
    
    return res
end

return M