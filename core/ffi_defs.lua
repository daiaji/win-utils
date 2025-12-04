local ffi = require 'ffi'
-- Load SDK definitions
require 'ffi.req' 'Windows.sdk.minwindef'
require 'ffi.req' 'Windows.sdk.ntdll'
require 'ffi.req' 'Windows.sdk.winioctl'

-- Ensure NTSTATUS is available
if not pcall(function() return ffi.sizeof("NTSTATUS") end) then
    ffi.cdef [[ typedef int32_t NTSTATUS; ]]
end

-- Common Constants (Global C Namespace)
ffi.cdef [[
    static const uint32_t GENERIC_READ             = 0x80000000;
    static const uint32_t GENERIC_WRITE            = 0x40000000;
    static const uint32_t GENERIC_EXECUTE          = 0x20000000;
    static const uint32_t GENERIC_ALL              = 0x10000000;
    static const uint32_t DELETE                   = 0x00010000;

    static const uint32_t FILE_SHARE_READ          = 0x00000001;
    static const uint32_t FILE_SHARE_WRITE         = 0x00000002;
    static const uint32_t FILE_SHARE_DELETE        = 0x00000004;

    static const uint32_t CREATE_NEW               = 1;
    static const uint32_t CREATE_ALWAYS            = 2;
    static const uint32_t OPEN_EXISTING            = 3;
    static const uint32_t OPEN_ALWAYS              = 4;
    static const uint32_t TRUNCATE_EXISTING        = 5;

    static const uint32_t FILE_ATTRIBUTE_NORMAL    = 0x00000080;
    static const uint32_t FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    static const uint32_t FILE_FLAG_NO_BUFFERING   = 0x20000000;
    static const uint32_t FILE_FLAG_WRITE_THROUGH  = 0x80000000;
    
    /* [REMOVED] INVALID_FILE_ATTRIBUTES is already defined in minwindef.lua */
]]

return ffi.C