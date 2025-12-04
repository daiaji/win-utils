local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

function M.open_process_token(pid, access)
    local hProcess = kernel32.OpenProcess(access or C.PROCESS_QUERY_INFORMATION, false, pid)
    if not hProcess then return nil, util.format_error() end
    
    local hToken = ffi.new("HANDLE[1]")
    -- TOKEN_ADJUST_PRIVILEGES(0x20) | TOKEN_QUERY(0x8)
    local status = ntdll.NtOpenProcessToken(hProcess, bit.bor(0x0020, 0x0008), hToken)
    
    kernel32.CloseHandle(hProcess) 
    
    if status < 0 then return nil, string.format("0x%X", status) end
    return Handle(hToken[0])
end

function M.set_privilege(token_handle, priv_name, enable)
    local raw = (type(token_handle)=="table" and token_handle.get) and token_handle:get() or token_handle
    
    -- [FIX] Use standard LUID struct from minwindef
    local luid = ffi.new("LUID")
    
    if advapi32.LookupPrivilegeValueW(nil, util.to_wide(priv_name), luid) == 0 then 
        return false 
    end

    -- [FIX] Use TOKEN_PRIVILEGES_NT defined in ntdll.lua (which uses LUID)
    local tp = ffi.new("TOKEN_PRIVILEGES_NT")
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = enable and 2 or 0 -- SE_PRIVILEGE_ENABLED
    
    local status = ntdll.NtAdjustPrivilegesToken(raw, false, tp, ffi.sizeof(tp), nil, nil)
    return status >= 0
end

function M.enable_privilege(name)
    local pid = kernel32.GetCurrentProcessId()
    local hToken, err = M.open_process_token(pid, C.PROCESS_QUERY_INFORMATION)
    if not hToken then return false, err end
    
    local ok = M.set_privilege(hToken, name, true)
    hToken:close()
    return ok
end

function M.get_user(token_handle)
    local raw = (type(token_handle)=="table" and token_handle.get) and token_handle:get() or token_handle
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    -- TokenUser = 1
    if ntdll.NtQueryInformationToken(raw, 1, buf, 1024, len) < 0 then return nil end
    
    local user = ffi.cast("SID_AND_ATTRIBUTES*", buf)
    local str_sid = ffi.new("LPWSTR[1]")
    if advapi32.ConvertSidToStringSidW(user.Sid, str_sid) == 0 then return nil end
    
    local res = util.from_wide(str_sid[0])
    kernel32.LocalFree(str_sid[0])
    return res
end

function M.get_integrity_level(token_handle)
    local raw = (type(token_handle)=="table" and token_handle.get) and token_handle:get() or token_handle
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    -- TokenIntegrityLevel = 25
    if ntdll.NtQueryInformationToken(raw, 25, buf, 1024, len) < 0 then return nil end
    
    local label = ffi.cast("TOKEN_MANDATORY_LABEL*", buf)
    local sid_ptr = ffi.cast("uint8_t*", label.Label.Sid)
    
    -- SubAuthorityCount is at offset 1
    local count = sid_ptr[1]
    -- Last SubAuthority is at offset 8 + (count-1)*4
    local rid = ffi.cast("DWORD*", sid_ptr + 8 + (count-1)*4)[0]
    
    if rid < 0x1000 then return "Untrusted"
    elseif rid < 0x2000 then return "Low"
    elseif rid < 0x3000 then return "Medium"
    elseif rid < 0x4000 then return "High"
    elseif rid < 0x5000 then return "System"
    else return "Protected" end
end

function M.is_elevated()
    local hToken = M.open_process_token(kernel32.GetCurrentProcessId())
    if not hToken then return false end
    
    local elev = ffi.new("TOKEN_ELEVATION")
    local len = ffi.new("ULONG[1]")
    -- TokenElevation = 20
    local status = ntdll.NtQueryInformationToken(hToken:get(), 20, elev, ffi.sizeof(elev), len)
    hToken:close()
    return status >= 0 and elev.TokenIsElevated ~= 0
end

return M