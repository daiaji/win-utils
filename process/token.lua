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
    if ntdll.NtOpenProcessToken(kernel32.GetCurrentProcess(), acc or 0x28, hToken) < 0 then 
        return nil 
    end
    return Handle(hToken[0])
end

-- 打开指定进程的令牌
function M.open_process(pid, acc)
    local hProc = kernel32.OpenProcess(0x0400, false, pid) -- PROCESS_QUERY_INFORMATION
    if not hProc then return nil end
    
    local hToken = ffi.new("HANDLE[1]")
    -- 默认权限: TOKEN_QUERY (8) | TOKEN_DUPLICATE (2) = 0xA
    local status = ntdll.NtOpenProcessToken(hProc, acc or 0xA, hToken)
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return nil end
    return Handle(hToken[0])
end

--------------------------------------------------------------------------------
-- 2. 特权管理 (Privilege Management)
--------------------------------------------------------------------------------

-- 启用指定特权 (如 SeDebugPrivilege)
-- 在 PE 中虽然默认拥有特权，但某些特权位默认是 Disabled 的，仍需 Enable 才能生效。
function M.enable_privilege(name)
    local hToken = M.open_current(0x28) -- ADJUIST_PRIVILEGES | QUERY
    if not hToken then return false end
    
    local luid = ffi.new("LUID")
    if advapi32.LookupPrivilegeValueW(nil, util.to_wide(name), luid) == 0 then
        return false, "Lookup failed"
    end
    
    local tp = ffi.new("TOKEN_PRIVILEGES")
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = 2 -- SE_PRIVILEGE_ENABLED
    
    -- AdjustTokenPrivileges 返回非零表示函数执行成功，但不代表特权调整成功
    local res = advapi32.AdjustTokenPrivileges(hToken:get(), false, tp, 0, nil, nil)
    local err = kernel32.GetLastError()
    
    if res == 0 or err == 1300 then -- ERROR_NOT_ALL_ASSIGNED = 1300
        return false, "Not all assigned" 
    end
    
    return true
end

-- 检查当前进程是否已提权 (Admin/System)
function M.is_elevated()
    local hToken = M.open_current(8) -- TOKEN_QUERY
    if not hToken then return false end
    
    local elev = ffi.new("TOKEN_ELEVATION")
    local len = ffi.new("ULONG[1]")
    
    -- TokenElevation = 20
    if ntdll.NtQueryInformationToken(hToken:get(), 20, elev, ffi.sizeof(elev), len) < 0 then
        return false
    end
    
    return elev.TokenIsElevated ~= 0
end

--------------------------------------------------------------------------------
-- 3. 令牌信息查询 (Token Info)
--------------------------------------------------------------------------------

-- 获取令牌对应的用户名 (DOMAIN\User)
function M.get_user(h)
    local raw = (type(h)=="table" and h.get) and h:get() or h
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    -- TokenUser = 1
    if ntdll.NtQueryInformationToken(raw, 1, buf, 1024, len) < 0 then return nil end
    
    local u = ffi.cast("SID_AND_ATTRIBUTES*", buf)
    local str = ffi.new("LPWSTR[1]")
    
    if advapi32.ConvertSidToStringSidW(u.Sid, str) == 0 then return nil end
    
    local res = util.from_wide(str[0])
    kernel32.LocalFree(str[0])
    return res
end

-- 获取令牌完整性级别 (Low, Medium, High, System)
function M.get_integrity_level(h)
    local raw = (type(h)=="table" and h.get) and h:get() or h
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    
    -- TokenIntegrityLevel = 25
    if ntdll.NtQueryInformationToken(raw, 25, buf, 1024, len) < 0 then return nil end
    
    local lbl = ffi.cast("TOKEN_MANDATORY_LABEL*", buf)
    local sid = ffi.cast("uint8_t*", lbl.Label.Sid)
    
    -- 手动解析 SID 获取最后一个 SubAuthority (RID)
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
-- 4. 令牌盗取与模拟 (Token Stealing / Impersonation) - [RESTORED]
--------------------------------------------------------------------------------

-- 从指定 PID 复制令牌 (获取 Primary Token)
-- 典型场景：从 Winlogon/Explorer 复制令牌以改变身份
function M.duplicate_from(pid)
    -- 1. 打开目标进程
    local hProc = kernel32.OpenProcess(0x0400, false, pid) -- QUERY_INFORMATION
    if not hProc then return nil, "OpenProcess failed" end
    
    local hTargetToken = ffi.new("HANDLE[1]")
    -- TOKEN_DUPLICATE (2) | TOKEN_QUERY (8) = 0xA
    local status = ntdll.NtOpenProcessToken(hProc, 0xA, hTargetToken)
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return nil, "OpenToken failed" end
    local hRawToken = hTargetToken[0]
    
    -- 2. 复制令牌
    local hNewToken = ffi.new("HANDLE[1]")
    -- SecurityImpersonation(2), TokenPrimary(1), MAXIMUM_ALLOWED(0x2000000)
    local res = advapi32.DuplicateTokenEx(hRawToken, 0x02000000, nil, 2, 1, hNewToken)
    
    kernel32.CloseHandle(hRawToken)
    
    if res == 0 then return nil, "Duplicate failed" end
    
    return Handle(hNewToken[0])
end

-- 使用指定 Token 启动进程
-- @param token_handle: 必须是 Primary Token (通过 duplicate_from 获取)
-- @param cmd: 命令行
-- @param show: 显示模式 (SW_SHOW 等)
function M.exec_as(token_handle, cmd, show)
    local si = ffi.new("STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    si.dwFlags = 1 -- STARTF_USESHOWWINDOW
    si.wShowWindow = show or 1
    
    -- 必须指定桌面，否则 SYSTEM 启动的进程可能不可见
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
    
    -- 锚定字符串防止 GC
    local _ = wcmd 
    
    if res == 0 then return nil, util.last_error() end
    
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(pi.hProcess)
    return tonumber(pi.dwProcessId)
end

return M