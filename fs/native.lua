local ffi = require 'ffi'
local bit = require 'bit'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local token = require 'win-utils.process.token'

local M = {}
local C = ffi.C

ffi.cdef [[
    BOOL ConvertStringSidToSidW(LPCWSTR StringSid, PSID* Sid);
]]

-- [FIX] Define constants locally to ensure stability regardless of SDK bindings
local FILE_DISPOSITION_DELETE = 0x00000001
local FILE_DISPOSITION_POSIX_SEMANTICS = 0x00000002
local FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE = 0x00000010

local function open_file_native(path, access)
    local flags = bit.bor(C.FILE_FLAG_BACKUP_SEMANTICS, C.OPEN_EXISTING)
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    
    local hFile = kernel32.CreateFileW(util.to_wide(path), access, share, nil, C.OPEN_EXISTING, C.FILE_FLAG_BACKUP_SEMANTICS, nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return nil, util.format_error() end
    return Handle.new(hFile)
end

function M.force_delete(path)
    -- 1. 打开文件 (需 DELETE 权限)
    local hFileObj = open_file_native(path, 0x00010000) -- DELETE
    if not hFileObj then return false, "Open failed" end
    
    -- 2. 使用 POSIX 语义删除 (Win10+)
    local iosb = ffi.new("IO_STATUS_BLOCK")
    local info_ex = ffi.new("FILE_DISPOSITION_INFO_EX")
    
    info_ex.Flags = bit.bor(
        FILE_DISPOSITION_DELETE,
        FILE_DISPOSITION_POSIX_SEMANTICS,
        FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE
    )
    
    -- FileDispositionInformationEx = 64
    local status = ntdll.NtSetInformationFile(hFileObj:get(), iosb, info_ex, ffi.sizeof(info_ex), 64)
    
    -- RAII Close 触发删除
    hFileObj:close()
    
    if status < 0 then 
        return false, string.format("Delete failed: 0x%X", status) 
    end
    return true
end

function M.set_times(path, ctime, atime, wtime)
    local hFileObj = open_file_native(path, C.GENERIC_WRITE)
    if not hFileObj then return false, "Open failed" end
    
    local info = ffi.new("FILE_BASIC_INFORMATION")
    info.CreationTime.QuadPart   = ctime or 0
    info.LastAccessTime.QuadPart = atime or 0
    info.LastWriteTime.QuadPart  = wtime or 0
    info.ChangeTime.QuadPart     = 0
    info.FileAttributes          = 0
    
    local iosb = ffi.new("IO_STATUS_BLOCK")
    -- FileBasicInformation = 4
    local status = ntdll.NtSetInformationFile(hFileObj:get(), iosb, info, ffi.sizeof(info), 4)
    
    hFileObj:close()
    return status >= 0
end

function M.set_attributes(path, attr_mask)
    local hFileObj = open_file_native(path, C.GENERIC_WRITE)
    if not hFileObj then return false, "Open failed" end
    
    local info = ffi.new("FILE_BASIC_INFORMATION")
    info.FileAttributes = attr_mask
    
    local iosb = ffi.new("IO_STATUS_BLOCK")
    local status = ntdll.NtSetInformationFile(hFileObj:get(), iosb, info, ffi.sizeof(info), 4)
    
    hFileObj:close()
    if status < 0 then return false, string.format("0x%X", status) end
    return true
end

function M.take_ownership(path)
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    local hFileObj = open_file_native(path, 0x00080000) -- WRITE_OWNER
    if not hFileObj then return false, "Open failed" end
    
    local pSid = ffi.new("PSID[1]")
    if advapi32.ConvertStringSidToSidW(util.to_wide("S-1-5-32-544"), pSid) == 0 then
         hFileObj:close()
         return false, "Create SID failed"
    end
    local admin_sid = pSid[0]
    
    local sd_buf = ffi.new("uint8_t[256]") 
    local sd = ffi.cast("PSECURITY_DESCRIPTOR", sd_buf)
    
    local ok = false
    -- OWNER_SECURITY_INFORMATION = 1
    if ntext.RtlCreateSecurityDescriptor(sd, 1) >= 0 then
        if ntext.RtlSetOwnerSecurityDescriptor(sd, admin_sid, 0) >= 0 then
            local status = ntext.NtSetSecurityObject(hFileObj:get(), 1, sd)
            ok = (status >= 0)
        end
    end
    
    kernel32.LocalFree(admin_sid)
    hFileObj:close()
    return ok
end

return M