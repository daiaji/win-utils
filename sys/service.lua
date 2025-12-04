local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local table_new = require 'table.new'

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
    local scm = open_scm(4) -- SC_MANAGER_ENUMERATE_SERVICE
    if not scm then return nil end
    
    local type_flag = drivers and 0x3B or 0x30 -- DRIVER or WIN32
    local bytes_needed = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    local resume = ffi.new("DWORD[1]", 0)
    local buf = nil
    local buf_size = 0
    
    -- 第一次调用获取大小
    advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, nil, 0, bytes_needed, count, resume, nil)
    local err = kernel32.GetLastError()
    if err ~= 234 then return nil end -- ERROR_MORE_DATA
    
    buf_size = bytes_needed[0]
    buf = ffi.new("uint8_t[?]", buf_size)
    
    if advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, buf, buf_size, bytes_needed, count, resume, nil) == 0 then
        return nil 
    end
    
    local num = tonumber(count[0])
    local res = table_new(num, 0)
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

function M.start(n) 
    local scm = open_scm(1) -- CONNECT
    if not scm then return false end
    
    local svc = open_svc(scm, n, 0x10) -- START
    if not svc then return false end
    
    local r = advapi32.StartServiceW(svc:get(), 0, nil)
    if r == 0 then
        local err = kernel32.GetLastError()
        if err == 1056 then return true end -- ALREADY_RUNNING
        return false
    end
    return true
end

function M.stop(n)
    local scm = open_scm(1)
    if not scm then return false end
    
    local svc = open_svc(scm, n, 0x24) -- STOP | QUERY_STATUS
    if not svc then return false end
    
    local st = ffi.new("SERVICE_STATUS")
    if advapi32.ControlService(svc:get(), 1, st) == 0 then -- SERVICE_CONTROL_STOP
        local err = kernel32.GetLastError()
        if err == 1062 then return true end -- SERVICE_NOT_ACTIVE
        return false
    end
    return true
end

-- 递归停止依赖服务
function M.stop_recursive(n)
    local deps = M.get_dependents(n)
    for _, d in ipairs(deps) do 
        M.stop_recursive(d) 
    end
    return M.stop(n)
end

function M.get_dependents(n)
    local scm = open_scm(1)
    if not scm then return {} end
    
    local svc = open_svc(scm, n, 8) -- ENUMERATE_DEPENDENTS
    if not svc then return {} end
    
    local bytes = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    
    -- 获取缓冲区大小
    advapi32.EnumDependentServicesW(svc:get(), 3, nil, 0, bytes, count)
    
    if bytes[0] == 0 then return {} end
    
    local buf = ffi.new("uint8_t[?]", bytes[0])
    if advapi32.EnumDependentServicesW(svc:get(), 3, ffi.cast("ENUM_SERVICE_STATUSW*", buf), bytes[0], bytes, count) == 0 then
        return {}
    end
    
    local deps = table_new(tonumber(count[0]), 0)
    local ptr = ffi.cast("ENUM_SERVICE_STATUSW*", buf)
    
    for i=0, count[0]-1 do 
        table.insert(deps, util.from_wide(ptr[i].lpServiceName)) 
    end
    return deps
end

return M