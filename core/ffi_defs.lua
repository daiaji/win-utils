local ffi = require 'ffi'
-- Load SDK definitions
require 'ffi.req' 'Windows.sdk.minwindef'
require 'ffi.req' 'Windows.sdk.ntdll'
require 'ffi.req' 'Windows.sdk.winioctl'
-- kernel32 defines most constants (GENERIC_*, FILE_SHARE_*, etc.)
-- We ensure it's loaded so ffi.C has them.
require 'ffi.req' 'Windows.sdk.kernel32'

-- Ensure NTSTATUS is available
if not pcall(function() return ffi.sizeof("NTSTATUS") end) then
    ffi.cdef [[ typedef int32_t NTSTATUS; ]]
end

-- [Cleaned] Most constants are already defined in kernel32.lua or minwindef.lua.
-- We only define what might be missing or specific helpers.
-- Currently empty to avoid "attempt to redefine" errors.

return ffi.C