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

-- [DEBUG] Force flush
local function log(msg)
    io.write(tostring(msg) .. "\n")
    io.stdout:flush()
end

ffi.cdef [[
    BOOL ConvertStringSidToSidW(LPCWSTR StringSid, PSID* Sid);
    
    typedef struct _FILE_DISPOSITION_INFORMATION {
        BOOLEAN DeleteFile;
    } FILE_DISPOSITION_INFORMATION;
]]

-- [FIX] Define constants locally to ensure stability
local FILE_DISPOSITION_DELETE = 0x00000001
local FILE_DISPOSITION_POSIX_SEMANTICS = 0x00000002
local FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE = 0x00000010

-- [DEBUG] Local safe to_wide implementation
local function safe_to_wide(str)
    log("[SAFE_TO_WIDE] Entry. Str type: " .. type(str))
    if not str then return nil end
    local len = #str
    log("[SAFE_TO_WIDE] Len: " .. len)
    
    -- Check kernel32 binding
    if not kernel32 then log("[SAFE_TO_WIDE] FATAL: kernel32 is nil") return nil end
    if not kernel32.MultiByteToWideChar then log("[SAFE_TO_WIDE] FATAL: MultiByteToWideChar is nil") return nil end
    
    log("[SAFE_TO_WIDE] Calling MultiByteToWideChar (Calc Len)...")
    -- CP_UTF8 = 65001
    local req = kernel32.MultiByteToWideChar(65001, 0, str, len, nil, 0)
    log("[SAFE_TO_WIDE] Req size: " .. tostring(req))
    
    if req == 0 then 
        log("[SAFE_TO_WIDE] Failed to calc len. Err: " .. kernel32.GetLastError())
        return nil 
    end
    
    log("[SAFE_TO_WIDE] Allocating buffer...")
    local buf = ffi.new("wchar_t[?]", req + 1)
    
    log("[SAFE_TO_WIDE] Calling MultiByteToWideChar (Write)...")
    kernel32.MultiByteToWideChar(65001, 0, str, len, buf, req)
    buf[req] = 0
    
    log("[SAFE_TO_WIDE] Success.")
    return buf
end

local function open_file_native(path, access)
    log("[NATIVE] Opening: " .. tostring(path))
    
    -- [DEBUG] Call safe_to_wide directly with logs
    local status, wpath = pcall(safe_to_wide, path)
    
    if not status then
        log("[NATIVE] safe_to_wide CRASHED: " .. tostring(wpath))
        return nil, "Encoding crash"
    end
    
    if not wpath then 
        log("[NATIVE] safe_to_wide returned nil")
        return nil, "Invalid path encoding" 
    end
    
    log(string.format("[NATIVE] wpath ptr: %s", tostring(wpath)))

    local flag_backup = 0x02000000 -- FILE_FLAG_BACKUP_SEMANTICS
    local flag_exist = 3           -- OPEN_EXISTING
    local share = 7                -- READ|WRITE|DELETE
    local flags = bit.bor(flag_backup, flag_exist)
    local creation = flag_exist
    
    log(string.format("[NATIVE] CreateFileW calling... Access=%X Share=%X", access, share))
    
    -- CreateFileW(LPCWSTR, DWORD, DWORD, void*, DWORD, DWORD, HANDLE)
    local hFile = kernel32.CreateFileW(
        wpath, 
        ffi.cast("DWORD", access), 
        ffi.cast("DWORD", share), 
        nil, 
        ffi.cast("DWORD", creation), 
        ffi.cast("DWORD", flag_backup), -- FlagsAndAttributes
        nil
    )
    
    log("[NATIVE] CreateFileW returned: " .. tostring(hFile))
        
    if hFile == ffi.cast("HANDLE", -1) then 
        local err = kernel32.GetLastError()
        log("[NATIVE] Open failed. Err=" .. err)
        return nil, util.format_error(err) 
    end
    
    log("[NATIVE] Wrapping handle...")
    local hObj = Handle.new(hFile)
    log("[NATIVE] Handle wrapped.")
    return hObj
end

function M.force_delete(path)
    log("[NATIVE] force_delete entry: " .. tostring(path))
    
    -- 1. 打开文件 (需 DELETE 权限)
    local hFileObj, err = open_file_native(path, 0x00010000) -- DELETE
    if not hFileObj then 
        log("[NATIVE] Open failed: " .. tostring(err))
        return false, "Open failed: " .. tostring(err) 
    end
    
    log("[NATIVE] Allocating IO_STATUS_BLOCK...")
    -- 2. 尝试使用 POSIX 语义删除 (Win10 1709+)
    local iosb = ffi.new("IO_STATUS_BLOCK")
    local info_ex = ffi.new("FILE_DISPOSITION_INFO_EX")
    
    info_ex.Flags = bit.bor(
        FILE_DISPOSITION_DELETE,
        FILE_DISPOSITION_POSIX_SEMANTICS,
        FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE
    )
    
    log("[NATIVE] Calling NtSetInformationFile (Class 64)... Handle=" .. tostring(hFileObj:get()))
    -- FileDispositionInformationEx = 64
    local status = ntdll.NtSetInformationFile(hFileObj:get(), iosb, info_ex, ffi.sizeof(info_ex), 64)
    log(string.format("[NATIVE] Class 64 Result: 0x%X", status))
    
    -- 3. 如果 POSIX 删除失败，尝试传统删除
    if status < 0 then
        log("[NATIVE] Fallback to classic DeleteFile logic (Class 13)...")
        local info = ffi.new("FILE_DISPOSITION_INFORMATION")
        info.DeleteFile = 1
        
        -- FileDispositionInformation = 13
        status = ntdll.NtSetInformationFile(hFileObj:get(), iosb, info, ffi.sizeof(info), 13)
        log(string.format("[NATIVE] Class 13 Result: 0x%X", status))
    end
    
    log("[NATIVE] Closing handle...")
    -- RAII Close 触发删除
    hFileObj:close()
    log("[NATIVE] Handle closed.")
    
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