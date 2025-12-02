local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local psapi = require 'ffi.req' 'Windows.sdk.psapi'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

function M.list(pid)
    local hProc = kernel32.OpenProcess(
        bit.bor(C.PROCESS_QUERY_INFORMATION, C.PROCESS_VM_READ), 
        false, pid
    )
    if not hProc then return nil, util.format_error() end
    hProc = Handle.guard(hProc)

    local hMods = ffi.new("HMODULE[1024]")
    local cbNeeded = ffi.new("DWORD[1]")
    
    if psapi.EnumProcessModulesEx(hProc, hMods, ffi.sizeof(hMods), cbNeeded, 0x03) == 0 then
        return nil, util.format_error()
    end
    
    local count = cbNeeded[0] / ffi.sizeof("HMODULE")
    local modules = {}
    local path_buf = ffi.new("wchar_t[1024]")
    
    for i = 0, count - 1 do
        if psapi.GetModuleFileNameExW(hProc, hMods[i], path_buf, 1024) > 0 then
            table.insert(modules, util.from_wide(path_buf))
        end
    end
    
    return modules
end

return M