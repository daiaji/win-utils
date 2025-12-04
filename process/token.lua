local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'

local M = {}

function M.open_current(acc)
    local hToken = ffi.new("HANDLE[1]")
    if ntdll.NtOpenProcessToken(kernel32.GetCurrentProcess(), acc, hToken) < 0 then return nil end
    return Handle(hToken[0])
end

function M.open(pid, acc)
    local hP = kernel32.OpenProcess(0x400, false, pid)
    if not hP then return nil end
    local hT = ffi.new("HANDLE[1]")
    local s = ntdll.NtOpenProcessToken(hP, acc, hT)
    kernel32.CloseHandle(hP)
    if s < 0 then return nil end
    return Handle(hT[0])
end

function M.enable_privilege(name)
    local h = M.open_current(0x20)
    if not h then return false end
    local luid = ffi.new("LUID")
    if advapi32.LookupPrivilegeValueW(nil, util.to_wide(name), luid) == 0 then h:close(); return false end
    local tp = ffi.new("TOKEN_PRIVILEGES_NT")
    tp.PrivilegeCount = 1; tp.Privileges[0].Luid = luid; tp.Privileges[0].Attributes = 2
    local res = ntdll.NtAdjustPrivilegesToken(h:get(), false, tp, ffi.sizeof(tp), nil, nil)
    h:close()
    return res >= 0
end

function M.is_elevated()
    local h = M.open_current(8)
    if not h then return false end
    local el = ffi.new("TOKEN_ELEVATION")
    local len = ffi.new("ULONG[1]")
    local res = ntdll.NtQueryInformationToken(h:get(), 20, el, ffi.sizeof(el), len)
    h:close()
    return res >= 0 and el.TokenIsElevated ~= 0
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