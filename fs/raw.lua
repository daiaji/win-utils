local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local util = require 'win-utils.core.util'
local C = require 'win-utils.core.ffi_defs'

local M = {}

function M.delete_posix(path)
    -- [FIX] Use "rd" (Read + Delete) instead of "rwd". 
    -- "w" adds GENERIC_WRITE which fails on ReadOnly files.
    -- FileDispositionInformation only requires DELETE access.
    local h, e = native.open_file(path, "rd", "exclusive")
    if not h then return false, e end
    
    local info = ffi.new("FILE_DISPOSITION_INFO_EX"); info.Flags = 0x13 -- Delete | Posix | IgnoreReadOnly
    local io = ffi.new("IO_STATUS_BLOCK")
    local s = ntdll.NtSetInformationFile(h:get(), io, info, ffi.sizeof(info), 64)
    h:close()
    return s >= 0
end

function M.set_times(path, c, a, w)
    local access = C.FILE_WRITE_ATTRIBUTES
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    local flags = bit.bor(C.FILE_ATTRIBUTE_NORMAL, C.FILE_FLAG_BACKUP_SEMANTICS)
    
    local h = native.open_internal(path, access, share, C.OPEN_EXISTING, flags)
    if not h then return false end
    
    local i = ffi.new("FILE_BASIC_INFORMATION")
    i.CreationTime.QuadPart = c or 0; i.LastAccessTime.QuadPart = a or 0; i.LastWriteTime.QuadPart = w or 0
    local io = ffi.new("IO_STATUS_BLOCK")
    local s = ntdll.NtSetInformationFile(h:get(), io, i, ffi.sizeof(i), 4)
    h:close()
    return s >= 0
end

function M.set_attributes(path, attr)
    local access = C.FILE_WRITE_ATTRIBUTES
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    local flags = bit.bor(C.FILE_ATTRIBUTE_NORMAL, C.FILE_FLAG_BACKUP_SEMANTICS)
    
    local h = native.open_internal(path, access, share, C.OPEN_EXISTING, flags)
    if not h then return false end
    
    local i = ffi.new("FILE_BASIC_INFORMATION"); i.FileAttributes = attr
    local io = ffi.new("IO_STATUS_BLOCK")
    local s = ntdll.NtSetInformationFile(h:get(), io, i, ffi.sizeof(i), 4)
    h:close()
    return s >= 0
end

function M.take_ownership(path)
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    local h = native.open_internal(path, 0x00080000, 0, 3, 0) -- WRITE_OWNER
    if not h then return false end
    
    local sid = ffi.new("PSID[1]")
    if advapi32.ConvertStringSidToSidW(util.to_wide("S-1-5-32-544"), sid) == 0 then h:close(); return false end
    
    local sd_buf = ffi.new("uint8_t[256]")
    local sd = ffi.cast("PSECURITY_DESCRIPTOR", sd_buf)
    
    local ok = false
    if ntext.RtlCreateSecurityDescriptor(sd, 1) >= 0 then
        if ntext.RtlSetOwnerSecurityDescriptor(sd, sid[0], 0) >= 0 then
            if ntext.NtSetSecurityObject(h:get(), 1, sd) >= 0 then ok = true end
        end
    end
    
    kernel32.LocalFree(sid[0])
    h:close()
    return ok
end

return M