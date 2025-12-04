local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'

local M = {}
local function close_svc(h) advapi32.CloseServiceHandle(h) end

local function open_scm(acc)
    local h = advapi32.OpenSCManagerW(nil,nil,acc)
    return h and Handle(h, close_svc) or nil
end

local function open_svc(scm, n, acc)
    local h = advapi32.OpenServiceW(scm:get(), util.to_wide(n), acc)
    return h and Handle(h, close_svc) or nil
end

function M.list(drivers)
    local scm = open_scm(4) -- ENUM
    if not scm then return nil end
    local type = drivers and 0x3B or 0x30
    local b, c, r = ffi.new("DWORD[1]"), ffi.new("DWORD[1]"), ffi.new("DWORD[1]", 0)
    advapi32.EnumServicesStatusExW(scm:get(), 0, type, 3, nil, 0, b, c, r, nil)
    local buf = ffi.new("uint8_t[?]", b[0])
    if advapi32.EnumServicesStatusExW(scm:get(), 0, type, 3, buf, b[0], b, c, r, nil) == 0 then return nil end
    local res = {}
    local ptr = ffi.cast("ENUM_SERVICE_STATUS_PROCESSW*", buf)
    for i=0, tonumber(c[0])-1 do
        table.insert(res, {
            name = util.from_wide(ptr[i].lpServiceName),
            display = util.from_wide(ptr[i].lpDisplayName),
            status = tonumber(ptr[i].ServiceStatusProcess.dwCurrentState),
            pid = tonumber(ptr[i].ServiceStatusProcess.dwProcessId)
        })
    end
    return res
end

function M.query(n)
    local scm = open_scm(1); if not scm then return nil end
    local svc = open_svc(scm, n, 4); if not svc then return nil end
    local buf = ffi.new("uint8_t[128]")
    local req = ffi.new("DWORD[1]")
    if advapi32.QueryServiceStatusEx(svc:get(), 0, buf, 128, req) == 0 then return nil end
    local s = ffi.cast("SERVICE_STATUS_PROCESS*", buf)
    return { status = tonumber(s.dwCurrentState), pid = tonumber(s.dwProcessId), exit = tonumber(s.dwWin32ExitCode) }
end

function M.set_config(n, start)
    local scm = open_scm(1); if not scm then return false end
    local svc = open_svc(scm, n, 2); if not svc then return false end
    return advapi32.ChangeServiceConfigW(svc:get(), 0xFFFFFFFF, start, 0xFFFFFFFF, nil,nil,nil,nil,nil,nil,nil) ~= 0
end

function M.get_dependents(n)
    local scm = open_scm(1); if not scm then return {} end
    local svc = open_svc(scm, n, 8); if not svc then return {} end
    local b, c = ffi.new("DWORD[1]"), ffi.new("DWORD[1]")
    advapi32.EnumDependentServicesW(svc:get(), 3, nil, 0, b, c)
    local buf = ffi.new("uint8_t[?]", b[0])
    if advapi32.EnumDependentServicesW(svc:get(), 3, ffi.cast("ENUM_SERVICE_STATUSW*", buf), b[0], b, c) == 0 then return {} end
    local deps, ptr = {}, ffi.cast("ENUM_SERVICE_STATUSW*", buf)
    for i=0, c[0]-1 do table.insert(deps, util.from_wide(ptr[i].lpServiceName)) end
    return deps
end

function M.start(n) 
    local scm = open_scm(1); if not scm then return false end
    local svc = open_svc(scm, n, 0x10); if not svc then return false end
    local r = advapi32.StartServiceW(svc:get(), 0, nil); 
    if r==0 and kernel32.GetLastError()==1056 then return true end
    return r~=0
end

function M.stop(n)
    local scm = open_scm(1); if not scm then return false end
    local svc = open_svc(scm, n, 0x24); if not svc then return false end
    local st = ffi.new("SERVICE_STATUS")
    local r = advapi32.ControlService(svc:get(), 1, st)
    if r==0 and kernel32.GetLastError()==1062 then return true end
    return r~=0
end

function M.stop_recursive(n)
    for _, d in ipairs(M.get_dependents(n)) do M.stop_recursive(d) end
    return M.stop(n)
end

return M