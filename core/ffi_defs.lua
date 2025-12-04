local ffi = require 'ffi'
-- Load SDK definitions to populate ffi.C
require 'ffi.req' 'Windows.sdk.minwindef'
require 'ffi.req' 'Windows.sdk.ntdll'
require 'ffi.req' 'Windows.sdk.winioctl'
require 'ffi.req' 'Windows.sdk.kernel32'

-- Ensure NTSTATUS is available (usually undefined in stock LuaJIT)
if not pcall(function() return ffi.sizeof("NTSTATUS") end) then
    ffi.cdef [[ typedef int32_t NTSTATUS; ]]
end

-- [Cleaned] All core constants are now in kernel32.lua
return ffi.C