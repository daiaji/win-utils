local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 参考 phlib: PhOpenProcessToken
function M.open_process_token(pid, access)
    local hProcess = kernel32.OpenProcess(access or C.PROCESS_QUERY_INFORMATION, false, pid)
    if hProcess == nil then return nil, util.format_error() end
    
    -- RAII
    hProcess = Handle.guard(hProcess)
    
    local hToken = ffi.new("HANDLE[1]")
    local status = ntdll.NtOpenProcessToken(hProcess, bit.bor(C.TOKEN_ADJUST_PRIVILEGES, C.TOKEN_QUERY), hToken)
    
    if status < 0 then return nil, "NtOpenProcessToken failed: " .. string.format("0x%X", status) end
    
    return Handle.guard(hToken[0])
end

-- 参考 phlib: PhSetTokenPrivilege
function M.set_privilege(token_handle, priv_name, enable)
    local luid = ffi.new("LUID_NT")
    if advapi32.LookupPrivilegeValueW(nil, util.to_wide(priv_name), ffi.cast("LUID*", luid)) == 0 then
        return false, "LookupPrivilegeValueW failed"
    end

    local tp = ffi.new("TOKEN_PRIVILEGES_NT")
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = enable and C.SE_PRIVILEGE_ENABLED or 0

    local status = ntdll.NtAdjustPrivilegesToken(token_handle, false, tp, ffi.sizeof(tp), nil, nil)
    
    if status < 0 then return false, string.format("0x%X", status) end
    if status == 0x00000106 then return false, "Not all privileges assigned" end

    return true
end

local function sid_to_string(sid_ptr)
    local str_sid_ptr = ffi.new("LPWSTR[1]")
    if advapi32.ConvertSidToStringSidW(sid_ptr, str_sid_ptr) == 0 then
        return nil
    end
    local str = util.from_wide(str_sid_ptr[0])
    kernel32.LocalFree(str_sid_ptr[0])
    return str
end

function M.get_user(token_handle)
    local buf_size = 1024
    local buf = ffi.new("uint8_t[?]", buf_size)
    local ret_len = ffi.new("ULONG[1]")
    
    local status = ntdll.NtQueryInformationToken(token_handle, C.TokenUser, buf, buf_size, ret_len)
    if status < 0 then return nil, string.format("0x%X", status) end
    
    local token_user = ffi.cast("SID_AND_ATTRIBUTES*", buf)
    return sid_to_string(token_user.Sid)
end

function M.get_integrity_level(token_handle)
    local buf_size = 1024
    local buf = ffi.new("uint8_t[?]", buf_size)
    local ret_len = ffi.new("ULONG[1]")

    local status = ntdll.NtQueryInformationToken(token_handle, C.TokenIntegrityLevel, buf, buf_size, ret_len)
    if status < 0 then return nil, string.format("0x%X", status) end

    local label = ffi.cast("TOKEN_MANDATORY_LABEL*", buf)
    local sub_auth_count = ffi.cast("uint8_t*", label.Label.Sid)[1]
    local rid_ptr = ffi.cast("DWORD*", ffi.cast("uint8_t*", label.Label.Sid) + 8 + (sub_auth_count - 1) * 4)
    local rid = rid_ptr[0]

    if rid < 0x1000 then return "Untrusted"
    elseif rid < 0x2000 then return "Low"
    elseif rid < 0x3000 then return "Medium"
    elseif rid < 0x4000 then return "High"
    elseif rid < 0x5000 then return "System"
    else return "Protected" end
end

function M.is_elevated(token_handle)
    local elev = ffi.new("TOKEN_ELEVATION")
    local ret_len = ffi.new("ULONG[1]")
    
    local status = ntdll.NtQueryInformationToken(token_handle, C.TokenElevation, elev, ffi.sizeof(elev), ret_len)
    if status < 0 then return false end
    
    return elev.TokenIsElevated ~= 0
end

function M.enable_privilege(name)
    local hToken, err = M.open_process_token(kernel32.GetCurrentProcessId(), C.PROCESS_QUERY_INFORMATION)
    if not hToken then return false, err end
    
    local ok, err = M.set_privilege(hToken, name, true)
    Handle.close(hToken)
    return ok, err
end

return M