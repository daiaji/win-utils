local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local class = require 'win-utils.deps'.class

local M = {}
local C = ffi.C

local function close_svc(h) advapi32.CloseServiceHandle(h) end

local function open_scm(acc)
    local h = advapi32.OpenSCManagerW(nil, nil, acc)
    if not h then return nil, util.format_error() end
    return Handle.new(h, close_svc)
end

local function open_svc(scm, name, acc)
    local h = advapi32.OpenServiceW(scm:get(), util.to_wide(name), acc)
    if not h then return nil, util.format_error() end
    return Handle.new(h, close_svc)
end

function M.list(drivers)
    local scm = open_scm(C.SC_MANAGER_ENUMERATE_SERVICE)
    if not scm then return nil end
    
    local type = drivers and 0x3B or 0x30 -- WIN32 vs +DRIVER
    local bytes = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    local resume = ffi.new("DWORD[1]", 0)
    
    advapi32.EnumServicesStatusExW(scm:get(), 0, type, 0x3, nil, 0, bytes, count, resume, nil)
    local buf = ffi.new("uint8_t[?]", bytes[0])
    
    if advapi32.EnumServicesStatusExW(scm:get(), 0, type, 0x3, buf, bytes[0], bytes, count, resume, nil) == 0 then return nil end
    
    local res = {}
    local ptr = ffi.cast("ENUM_SERVICE_STATUS_PROCESSW*", buf)
    for i = 0, tonumber(count[0]) - 1 do
        table.insert(res, {
            name = util.from_wide(ptr[i].lpServiceName),
            display = util.from_wide(ptr[i].lpDisplayName),
            status = tonumber(ptr[i].ServiceStatusProcess.dwCurrentState),
            pid = tonumber(ptr[i].ServiceStatusProcess.dwProcessId)
        })
    end
    return res
end

function M.start(name)
    local scm = open_scm(C.SC_MANAGER_CONNECT)
    if not scm then return false end
    local svc = open_svc(scm, name, C.SERVICE_START)
    if not svc then return false end
    if advapi32.StartServiceW(svc:get(), 0, nil) == 0 then
        local e = kernel32.GetLastError()
        if e == 1056 then return true end -- Already running
        return false, util.format_error(e)
    end
    return true
end

function M.stop(name)
    local scm = open_scm(C.SC_MANAGER_CONNECT)
    if not scm then return false end
    local svc = open_svc(scm, name, bit.bor(C.SERVICE_STOP, C.SERVICE_QUERY_STATUS))
    if not svc then return false end
    local buf = ffi.new("uint32_t[9]")
    if advapi32.ControlService(svc:get(), C.SERVICE_STOP, buf) == 0 then
        local e = kernel32.GetLastError()
        if e == 1062 then return true end -- Already stopped
        return false, util.format_error(e)
    end
    return true
end

function M.query(name)
    local scm = open_scm(C.SC_MANAGER_CONNECT)
    if not scm then return nil end
    local svc = open_svc(scm, name, C.SERVICE_QUERY_STATUS)
    if not svc then return nil end
    local buf = ffi.new("uint8_t[128]")
    local req = ffi.new("DWORD[1]")
    if advapi32.QueryServiceStatusEx(svc:get(), 0, buf, 128, req) == 0 then return nil end
    local s = ffi.cast("SERVICE_STATUS_PROCESS*", buf)
    return { status = tonumber(s.dwCurrentState), pid = tonumber(s.dwProcessId), exit = tonumber(s.dwWin32ExitCode) }
end

function M.set_config(name, start)
    local scm = open_scm(C.SC_MANAGER_CONNECT)
    if not scm then return false end
    local svc = open_svc(scm, name, C.SERVICE_CHANGE_CONFIG)
    if not svc then return false end
    return advapi32.ChangeServiceConfigW(svc:get(), 0xFFFFFFFF, start or 0xFFFFFFFF, 0xFFFFFFFF, nil, nil, nil, nil, nil, nil, nil) ~= 0
end

-- 获取依赖项
function M.get_dependents(name)
    local scm = open_scm(C.SC_MANAGER_CONNECT)
    if not scm then return nil end
    local svc = open_svc(scm, name, 0x0008) -- SERVICE_ENUMERATE_DEPENDENTS
    if not svc then return nil end
    
    local bytes = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    
    advapi32.EnumDependentServicesW(svc:get(), C.SERVICE_STATE_ALL, nil, 0, bytes, count)
    local buf = ffi.new("uint8_t[?]", bytes[0])
    
    if advapi32.EnumDependentServicesW(svc:get(), C.SERVICE_STATE_ALL, ffi.cast("ENUM_SERVICE_STATUSW*", buf), bytes[0], bytes, count) == 0 then
        return {}
    end
    
    local deps = {}
    local ptr = ffi.cast("ENUM_SERVICE_STATUSW*", buf)
    for i = 0, count[0] - 1 do
        table.insert(deps, util.from_wide(ptr[i].lpServiceName))
    end
    return deps
end

-- 递归停止
function M.stop_recursive(name)
    local deps = M.get_dependents(name)
    if deps then
        for _, dep in ipairs(deps) do
            M.stop_recursive(dep)
        end
    end
    return M.stop(name)
end

return M