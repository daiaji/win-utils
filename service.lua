local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

local function close_service_handle(h)
    if h and h ~= ffi.cast("SC_HANDLE", 0) then
        advapi32.CloseServiceHandle(h)
    end
end

local function open_scm(access)
    local hScm = advapi32.OpenSCManagerW(nil, nil, access or C.SC_MANAGER_ENUMERATE_SERVICE)
    if hScm == nil then return nil, util.format_error() end
    return Handle.guard(hScm, close_service_handle)
end

-- 列举所有服务
function M.list(include_drivers)
    local hScm, err = open_scm(C.SC_MANAGER_ENUMERATE_SERVICE)
    if not hScm then return nil, err end

    local service_type = C.SERVICE_WIN32
    if include_drivers then
        service_type = bit.bor(service_type, C.SERVICE_DRIVER)
    end

    local bytes_needed = ffi.new("DWORD[1]")
    local services_returned = ffi.new("DWORD[1]")
    local resume_handle = ffi.new("DWORD[1]", 0)
    local buf_size = 0

    -- 第一次调用获取所需缓冲区大小
    advapi32.EnumServicesStatusExW(hScm, C.SC_ENUM_PROCESS_INFO, service_type, 
        C.SERVICE_STATE_ALL, nil, 0, bytes_needed, services_returned, resume_handle, nil)
    
    local err_code = kernel32.GetLastError()
    if err_code ~= 234 and err_code ~= 0 then -- ERROR_MORE_DATA
        return nil, util.format_error(err_code)
    end

    buf_size = bytes_needed[0]
    local buf = ffi.new("uint8_t[?]", buf_size)
    
    -- 第二次调用获取数据
    if advapi32.EnumServicesStatusExW(hScm, C.SC_ENUM_PROCESS_INFO, service_type, 
        C.SERVICE_STATE_ALL, buf, buf_size, bytes_needed, services_returned, resume_handle, nil) == 0 then
        return nil, util.format_error()
    end

    local services = {}
    local struct_ptr = ffi.cast("ENUM_SERVICE_STATUS_PROCESSW*", buf)
    
    for i = 0, tonumber(services_returned[0]) - 1 do
        local s = struct_ptr[i]
        table.insert(services, {
            name = util.from_wide(s.lpServiceName),
            display_name = util.from_wide(s.lpDisplayName),
            status = tonumber(s.ServiceStatusProcess.dwCurrentState),
            pid = tonumber(s.ServiceStatusProcess.dwProcessId),
            type = tonumber(s.ServiceStatusProcess.dwServiceType)
        })
    end

    return services
end

function M.start(name)
    local hScm, err = open_scm(C.SC_MANAGER_CONNECT)
    if not hScm then return false, err end

    local hSvc = advapi32.OpenServiceW(hScm, util.to_wide(name), C.SERVICE_START)
    if hSvc == nil then return false, util.format_error() end
    hSvc = Handle.guard(hSvc, close_service_handle)

    if advapi32.StartServiceW(hSvc, 0, nil) == 0 then
        local e = kernel32.GetLastError()
        if e == 1056 then return true, "Already running" end
        return false, util.format_error(e)
    end
    return true
end

function M.stop(name)
    local hScm, err = open_scm(C.SC_MANAGER_CONNECT)
    if not hScm then return false, err end

    local hSvc = advapi32.OpenServiceW(hScm, util.to_wide(name), bit.bor(C.SERVICE_STOP, C.SERVICE_QUERY_STATUS))
    if hSvc == nil then return false, util.format_error() end
    hSvc = Handle.guard(hSvc, close_service_handle)

    local status_buf = ffi.new("uint32_t[9]") -- SERVICE_STATUS_PROCESS size safety
    if advapi32.ControlService(hSvc, C.SERVICE_STOP, status_buf) == 0 then
        local e = kernel32.GetLastError()
        if e == 1062 then return true, "Already stopped" end
        return false, util.format_error(e)
    end
    return true
end

function M.query(name)
    local hScm, err = open_scm(C.SC_MANAGER_CONNECT)
    if not hScm then return nil, err end

    local hSvc = advapi32.OpenServiceW(hScm, util.to_wide(name), C.SERVICE_QUERY_STATUS)
    if hSvc == nil then return nil, util.format_error() end
    hSvc = Handle.guard(hSvc, close_service_handle)

    local buf = ffi.new("uint8_t[128]")
    local needed = ffi.new("DWORD[1]")
    
    if advapi32.QueryServiceStatusEx(hSvc, 0, buf, 128, needed) == 0 then
        return nil, util.format_error()
    end

    local s = ffi.cast("SERVICE_STATUS_PROCESS*", buf)
    return {
        status = tonumber(s.dwCurrentState),
        pid = tonumber(s.dwProcessId),
        controls = tonumber(s.dwControlsAccepted),
        exit_code = tonumber(s.dwWin32ExitCode)
    }
end

-- 修改服务配置 (如启动类型)
-- start_type: 2 (Auto), 3 (Manual), 4 (Disabled)
function M.set_config(name, start_type)
    local hScm, err = open_scm(C.SC_MANAGER_CONNECT)
    if not hScm then return false, err end

    local hSvc = advapi32.OpenServiceW(hScm, util.to_wide(name), C.SERVICE_CHANGE_CONFIG) 
    if hSvc == nil then return false, util.format_error() end
    hSvc = Handle.guard(hSvc, close_service_handle)

    local NO_CHANGE = C.SERVICE_NO_CHANGE
    
    if advapi32.ChangeServiceConfigW(hSvc, NO_CHANGE, start_type or NO_CHANGE, NO_CHANGE, nil, nil, nil, nil, nil, nil, nil) == 0 then
        return false, util.format_error()
    end
    
    return true
end

-- [NEW] 获取依赖此服务的子服务
function M.get_dependents(name)
    local hScm = advapi32.OpenSCManagerW(nil, nil, C.SC_MANAGER_CONNECT)
    if not hScm then return nil end
    
    local hSvc = advapi32.OpenServiceW(hScm, util.to_wide(name), 0x0008) -- SERVICE_ENUMERATE_DEPENDENTS
    if not hSvc then advapi32.CloseServiceHandle(hScm); return nil end
    
    local bytes = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    
    -- 第一次调用获取大小
    advapi32.EnumDependentServicesW(hSvc, C.SERVICE_STATE_ALL, nil, 0, bytes, count)
    
    local buf = ffi.new("uint8_t[?]", bytes[0])
    local res = advapi32.EnumDependentServicesW(hSvc, C.SERVICE_STATE_ALL, ffi.cast("ENUM_SERVICE_STATUSW*", buf), bytes[0], bytes, count)
    
    local dependents = {}
    if res ~= 0 then
        local ptr = ffi.cast("ENUM_SERVICE_STATUSW*", buf)
        for i = 0, count[0] - 1 do
            table.insert(dependents, util.from_wide(ptr[i].lpServiceName))
        end
    end
    
    advapi32.CloseServiceHandle(hSvc)
    advapi32.CloseServiceHandle(hScm)
    return dependents
end

-- [NEW] 递归停止服务
function M.stop_recursive(name)
    local dependents = M.get_dependents(name)
    if dependents then
        for _, dep in ipairs(dependents) do
            -- 递归停止子服务
            M.stop_recursive(dep)
        end
    end
    -- 停止自己
    return M.stop(name)
end

return M