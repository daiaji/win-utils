local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local table_new = require 'table.new'
local table_ext = require 'ext.table'

local M = {}
local function close_svc(h) advapi32.CloseServiceHandle(h) end

-- [FIX] 显式检查句柄是否为 0，因为 cdata 指针在 Lua 中始终为 true
local function open_scm(acc)
    local h = advapi32.OpenSCManagerW(nil, nil, acc)
    if h == nil or h == ffi.cast("SC_HANDLE", 0) then return nil end
    return Handle(h, close_svc)
end

local function open_svc(scm, n, acc)
    local h = advapi32.OpenServiceW(scm:get(), util.to_wide(n), acc)
    if h == nil or h == ffi.cast("SC_HANDLE", 0) then return nil end
    return Handle(h, close_svc)
end

function M.list(drivers)
    local scm = open_scm(4) -- SC_MANAGER_ENUMERATE_SERVICE
    if not scm then return nil end
    
    local type_flag = drivers and 0x3B or 0x30
    local bytes_needed = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    local resume = ffi.new("DWORD[1]", 0)
    
    advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, nil, 0, bytes_needed, count, resume, nil)
    local err = kernel32.GetLastError()
    if err ~= 234 then return nil end
    
    local buf = ffi.new("uint8_t[?]", bytes_needed[0])
    if advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, buf, bytes_needed[0], bytes_needed, count, resume, nil) == 0 then
        return nil 
    end
    
    local num = tonumber(count[0])
    local res = table_new(num, 0)
    setmetatable(res, { __index = table_ext })
    
    local ptr = ffi.cast("ENUM_SERVICE_STATUS_PROCESSW*", buf)
    for i=0, num-1 do
        table.insert(res, {
            name = util.from_wide(ptr[i].lpServiceName),
            display = util.from_wide(ptr[i].lpDisplayName),
            status = tonumber(ptr[i].ServiceStatusProcess.dwCurrentState),
            pid = tonumber(ptr[i].ServiceStatusProcess.dwProcessId)
        })
    end
    return res
end

-- [Restored] Query detailed status
function M.query(n)
    local scm = open_scm(1) -- CONNECT
    if not scm then return nil end
    local svc = open_svc(scm, n, 4) -- QUERY_STATUS
    if not svc then return nil end
    
    local needed = ffi.new("DWORD[1]")
    local buf = ffi.new("uint8_t[512]")
    
    if advapi32.QueryServiceStatusEx(svc:get(), 0, buf, 512, needed) == 0 then
        return nil, util.last_error()
    end
    
    local s = ffi.cast("SERVICE_STATUS_PROCESS*", buf)
    return {
        status = tonumber(s.dwCurrentState),
        pid = tonumber(s.dwProcessId),
        code = tonumber(s.dwWin32ExitCode),
        svc_code = tonumber(s.dwServiceSpecificExitCode)
    }
end

function M.start(n) 
    local scm = open_scm(1) -- CONNECT
    if not scm then return false end
    local svc = open_svc(scm, n, 0x10) -- START
    if not svc then return false end
    
    local r = advapi32.StartServiceW(svc:get(), 0, nil)
    if r == 0 then
        local err = kernel32.GetLastError()
        if err == 1056 then return true end
        return false
    end
    return true
end

function M.stop(n)
    local scm = open_scm(1)
    if not scm then return false end
    local svc = open_svc(scm, n, 0x24) -- STOP | QUERY
    if not svc then return false end
    
    local st = ffi.new("SERVICE_STATUS")
    if advapi32.ControlService(svc:get(), 1, st) == 0 then
        local err = kernel32.GetLastError()
        if err == 1062 then return true end
        return false
    end
    return true
end

-- start_type: 2 (Auto), 3 (Manual), 4 (Disabled)
function M.set_config(n, start_type)
    local scm = open_scm(1)
    if not scm then return false end
    local svc = open_svc(scm, n, 2) -- CHANGE_CONFIG
    if not svc then return false end
    
    return advapi32.ChangeServiceConfigW(svc:get(), 0xFFFFFFFF, start_type, 0xFFFFFFFF, nil, nil, nil, nil, nil, nil, nil) ~= 0
end

function M.stop_recursive(n)
    local deps = M.get_dependents(n)
    if deps and #deps > 0 then
        for _, d in ipairs(deps) do M.stop_recursive(d) end
    end
    return M.stop(n)
end

function M.get_dependents(n)
    local scm = open_scm(1)
    if not scm then return {} end
    local svc = open_svc(scm, n, 8) -- ENUM_DEPENDENTS
    if not svc then return {} end
    
    local bytes = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    
    advapi32.EnumDependentServicesW(svc:get(), 3, nil, 0, bytes, count)
    if bytes[0] == 0 then return {} end
    
    local buf = ffi.new("uint8_t[?]", bytes[0])
    if advapi32.EnumDependentServicesW(svc:get(), 3, ffi.cast("ENUM_SERVICE_STATUSW*", buf), bytes[0], bytes, count) == 0 then
        return {}
    end
    
    local deps = table_new(tonumber(count[0]), 0)
    setmetatable(deps, { __index = table_ext })
    local ptr = ffi.cast("ENUM_SERVICE_STATUSW*", buf)
    for i=0, count[0]-1 do 
        table.insert(deps, util.from_wide(ptr[i].lpServiceName)) 
    end
    return deps
end

return M