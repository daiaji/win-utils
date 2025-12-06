local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'

local M = {}

-- 辅助：自动释放 SID 内存
local function free_sid(ptr) if ptr then kernel32.LocalFree(ptr) end end

--------------------------------------------------------------------------------
-- 1. 令牌获取 (Token Acquisition)
--------------------------------------------------------------------------------

-- 打开当前进程的令牌
function M.open_current(acc)
    local hToken = ffi.new("HANDLE[1]")
    -- 默认权限: TOKEN_QUERY (8) | TOKEN_ADJUST_PRIVILEGES (0x20) = 0x28
    local status = ntdll.NtOpenProcessToken(kernel32.GetCurrentProcess(), acc or 0x28, hToken)
    if status < 0 then 
        return nil, string.format("NtOpenProcessToken Failed: 0x%08X", status)
    end
    return Handle(hToken[0])
end

-- 打开指定进程的令牌
function M.open_process(pid, acc)
    local hProc = kernel32.OpenProcess(0x0400, false, pid) -- PROCESS_QUERY_INFORMATION
    if not hProc then return nil, util.last_error() end
    
    local hToken = ffi.new("HANDLE[1]")
    -- 默认权限: TOKEN_QUERY (8) | TOKEN_DUPLICATE (2) = 0xA
    local status = ntdll.NtOpenProcessToken(hProc, acc or 0xA, hToken)
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return nil, string.format("NtOpenProcessToken(PID=%d) Failed: 0x%08X", pid, status) end
    return Handle(hToken[0])
end

--------------------------------------------------------------------------------
-- 2. 特权管理 (Privilege Management)
--------------------------------------------------------------------------------

function M.enable_privilege(name)
    local hToken, err = M.open_current(0x28) -- ADJUIST_PRIVILEGES | QUERY
    if not hToken then return false, err end
    
    local luid = ffi.new("LUID")
    if advapi32.LookupPrivilegeValueW(nil, util.to_wide(name), luid) == 0 then
        return false, util.last_error()
    end
    
    local tp = ffi.new("TOKEN_PRIVILEGES")
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = 2 -- SE_PRIVILEGE_ENABLED
    
    local res = advapi32.AdjustTokenPrivileges(hToken:get(), false, tp, 0, nil, nil)
    local err_code = kernel32.GetLastError()
    
    if res == 0 then return false, "AdjustTokenPrivileges Failed: " .. err_code end
    if err_code == 1300 then return false, "Privilege not held" end
    
    return true
end

function M.is_elevated()
    local hToken = M.open_current(8) -- TOKEN_QUERY
    if not hToken then return false end
    
    local elev = ffi.new("TOKEN_ELEVATION")
    local len = ffi.new("ULONG[1]")
    
    if ntdll.NtQueryInformationToken(hToken:get(), 20, elev, ffi.sizeof(elev), len) < 0 then
        return false
    end
    
    return elev.TokenIsElevated ~= 0
end

--------------------------------------------------------------------------------
-- 3. 令牌信息查询 (Token Info)
--------------------------------------------------------------------------------

function M.get_user(h)
    local raw = (type(h)=="table" and h.get) and h:get() or h
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    if ntdll.NtQueryInformationToken(raw, 1, buf, 1024, len) < 0 then return nil end
    
    local u = ffi.cast("SID_AND_ATTRIBUTES*", buf)
    local str = ffi.new("LPWSTR[1]")
    
    if advapi32.ConvertSidToStringSidW(u.Sid, str) == 0 then return nil end
    
    local res = util.from_wide(str[0])
    kernel32.LocalFree(str[0])
    return res
end

function M.get_integrity_level(h)
    local raw = (type(h)=="table" and h.get) and h:get() or h
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    if ntdll.NtQueryInformationToken(raw, 25, buf, 1024, len) < 0 then return nil end
    
    local lbl = ffi.cast("TOKEN_MANDATORY_LABEL*", buf)
    local sid = ffi.cast("uint8_t*", lbl.Label.Sid)
    
    local sub_auth_count = sid[1]
    local rid_ptr = ffi.cast("DWORD*", sid + 8 + (sub_auth_count-1)*4)
    local rid = rid_ptr[0]
    
    if rid < 0x1000 then return "Untrusted"
    elseif rid < 0x2000 then return "Low"
    elseif rid < 0x3000 then return "Medium"
    elseif rid < 0x4000 then return "High"
    elseif rid < 0x5000 then return "System"
    else return "Protected" end
end

--------------------------------------------------------------------------------
-- 4. 令牌盗取与模拟
--------------------------------------------------------------------------------

function M.duplicate_from(pid)
    local hProc = kernel32.OpenProcess(0x0400, false, pid)
    if not hProc then return nil, util.last_error() end
    
    local hTargetToken = ffi.new("HANDLE[1]")
    local status = ntdll.NtOpenProcessToken(hProc, 0xA, hTargetToken)
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return nil, "OpenToken failed: " .. status end
    local hRawToken = hTargetToken[0]
    
    local hNewToken = ffi.new("HANDLE[1]")
    local res = advapi32.DuplicateTokenEx(hRawToken, 0x02000000, nil, 2, 1, hNewToken)
    
    kernel32.CloseHandle(hRawToken)
    
    if res == 0 then return nil, util.last_error() end
    
    return Handle(hNewToken[0])
end

function M.exec_as(token_handle, cmd, show)
    local si = ffi.new("STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    si.dwFlags = 1 -- STARTF_USESHOWWINDOW
    si.wShowWindow = show or 1
    si.lpDesktop = util.to_wide("winsta0\\default") 
    
    local pi = ffi.new("PROCESS_INFORMATION")
    local wcmd = util.to_wide(cmd)
    
    local raw_token = (type(token_handle)=="table" and token_handle.get) and token_handle:get() or token_handle
    
    local res = advapi32.CreateProcessAsUserW(
        raw_token,
        nil,
        wcmd,
        nil, nil,
        false,
        0, -- CreationFlags
        nil, nil,
        si, pi
    )
    
    local _ = wcmd 
    
    if res == 0 then return nil, util.last_error() end
    
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(pi.hProcess)
    return tonumber(pi.dwProcessId)
end

return M