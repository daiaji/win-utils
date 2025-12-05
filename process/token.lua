local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'

local M = {}

-- [PE Optimization] 
-- 在 WinPE 环境下，用户默认为 SYSTEM 或 Administrator，
-- 且拥有所有特权 (SeDebugPrivilege 等)。
-- 因此移除繁重的 Token 打开/调整逻辑，保留信息查询功能。

-- 模拟打开 Token，仅用于信息查询
function M.open_current(acc)
    local hToken = ffi.new("HANDLE[1]")
    if ntdll.NtOpenProcessToken(kernel32.GetCurrentProcess(), acc, hToken) < 0 then return nil end
    return Handle(hToken[0])
end

-- [PE Stub] 始终返回成功
-- PE 环境下默认拥有所有特权，无需调整
function M.enable_privilege(name)
    return true
end

-- [PE Stub] 始终视为已提权
function M.is_elevated()
    return true
end

function M.get_user(h)
    local raw = (h.get) and h:get() or h
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
    local raw = (h.get) and h:get() or h
    local buf = ffi.new("uint8_t[1024]")
    local len = ffi.new("ULONG[1]")
    if ntdll.NtQueryInformationToken(raw, 25, buf, 1024, len) < 0 then return nil end
    local lbl = ffi.cast("TOKEN_MANDATORY_LABEL*", buf)
    local sid = ffi.cast("uint8_t*", lbl.Label.Sid)
    local cnt = sid[1]
    local rid = ffi.cast("DWORD*", sid + 8 + (cnt-1)*4)[0]
    
    if rid < 0x1000 then return "Untrusted"
    elseif rid < 0x2000 then return "Low"
    elseif rid < 0x3000 then return "Medium"
    elseif rid < 0x4000 then return "High"
    elseif rid < 0x5000 then return "System"
    else return "Protected" end
end

return M