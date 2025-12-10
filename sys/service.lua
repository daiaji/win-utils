local ffi = require 'ffi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local table_new = require 'table.new'
local table_ext = require 'ext.table'

local M = {}

-- Constants
local SERVICE_CONFIG_DELAYED_AUTO_START_INFO = 3
local SC_MANAGER_CONNECT            = 0x0001
local SC_MANAGER_CREATE_SERVICE     = 0x0002
local SC_MANAGER_ENUMERATE_SERVICE  = 0x0004
local SERVICE_QUERY_STATUS          = 0x0004
local SERVICE_CHANGE_CONFIG         = 0x0002
local SERVICE_START                 = 0x0010
local SERVICE_STOP                  = 0x0020
local SERVICE_ENUMERATE_DEPENDENTS  = 0x0008
local DELETE                        = 0x00010000

-- Helper: Close Service Handle
local function close_svc(h) advapi32.CloseServiceHandle(h) end

-- Helper: Open SCM
local function open_scm(acc)
    local h = advapi32.OpenSCManagerW(nil, nil, acc)
    if h == nil or h == ffi.cast("SC_HANDLE", 0) then 
        return nil, util.last_error("OpenSCManager failed") 
    end
    return Handle(h, close_svc)
end

-- Helper: Open Service
local function open_svc(scm, n, acc)
    local h = advapi32.OpenServiceW(scm:get(), util.to_wide(n), acc)
    if h == nil or h == ffi.cast("SC_HANDLE", 0) then 
        return nil, util.last_error("OpenService failed")
    end
    return Handle(h, close_svc)
end

-- [Internal] Wait Logic
local function wait_logic(svc_name, target_status, timeout)
    local start = kernel32.GetTickCount()
    local limit = timeout or 30000 -- Default 30s
    
    while true do
        -- Use public query API to refresh status
        local info = M.query(svc_name)
        if not info then return false, "Query failed during wait" end
        
        if info.status == target_status then return true end
        
        if (kernel32.GetTickCount() - start) > limit then 
            return false, "Timeout waiting for service status" 
        end
        
        -- Smart sleep based on WaitHint from service
        local hint = info.wait_hint or 1000
        local sleep_ms = math.min(math.max(hint / 10, 100), 1000)
        kernel32.Sleep(sleep_ms)
    end
end

-- [API] List Services
-- @param drivers: bool, true=List Drivers, false=List Services
function M.list(drivers)
    local scm, err = open_scm(SC_MANAGER_ENUMERATE_SERVICE)
    if not scm then return nil, err end
    
    local type_flag = drivers and 0x3B or 0x30 -- 0x3B=Drivers, 0x30=Win32
    local bytes_needed = ffi.new("DWORD[1]")
    local count = ffi.new("DWORD[1]")
    local resume = ffi.new("DWORD[1]", 0)
    
    advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, nil, 0, bytes_needed, count, resume, nil)
    local err_code = kernel32.GetLastError()
    if err_code ~= 234 then return nil, util.last_error("EnumServices Size") end 
    
    local buf = ffi.new("uint8_t[?]", bytes_needed[0])
    if advapi32.EnumServicesStatusExW(scm:get(), 0, type_flag, 3, buf, bytes_needed[0], bytes_needed, count, resume, nil) == 0 then
        return nil, util.last_error("EnumServices failed")
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

-- [API] Query Detailed Status (Matches PECMD SERV output)
function M.query(n)
    local scm, err = open_scm(SC_MANAGER_CONNECT)
    if not scm then return nil, err end
    local svc, err2 = open_svc(scm, n, SERVICE_QUERY_STATUS)
    if not svc then return nil, err2 end
    
    local needed = ffi.new("DWORD[1]")
    local buf = ffi.new("uint8_t[512]")
    
    if advapi32.QueryServiceStatusEx(svc:get(), 0, buf, 512, needed) == 0 then
        return nil, util.last_error("QueryStatus failed")
    end
    
    local s = ffi.cast("SERVICE_STATUS_PROCESS*", buf)
    return {
        status      = tonumber(s.dwCurrentState),
        type        = tonumber(s.dwServiceType),
        controls    = tonumber(s.dwControlsAccepted),
        code        = tonumber(s.dwWin32ExitCode),
        svc_code    = tonumber(s.dwServiceSpecificExitCode),
        checkpoint  = tonumber(s.dwCheckPoint),
        wait_hint   = tonumber(s.dwWaitHint),
        pid         = tonumber(s.dwProcessId),
        flags       = tonumber(s.dwServiceFlags)
    }
end

-- [API] Start Service
-- @param wait: boolean (Wait for running state)
-- @param timeout: number (ms)
function M.start(n, wait, timeout) 
    local scm, err = open_scm(SC_MANAGER_CONNECT)
    if not scm then return false, err end
    local svc, err2 = open_svc(scm, n, SERVICE_START)
    if not svc then return false, err2 end
    
    local r = advapi32.StartServiceW(svc:get(), 0, nil)
    if r == 0 then
        local err_code = kernel32.GetLastError()
        if err_code == 1056 then -- ERROR_SERVICE_ALREADY_RUNNING
            if wait then return wait_logic(n, 4, timeout) end
            return true, "Already running"
        end
        return false, util.last_error("StartService failed")
    end
    
    if wait then
        return wait_logic(n, 4, timeout)
    end
    return true
end

-- [API] Stop Service
-- @param wait: boolean (Wait for stopped state)
-- @param timeout: number (ms)
function M.stop(n, wait, timeout)
    local scm, err = open_scm(SC_MANAGER_CONNECT)
    if not scm then return false, err end
    local svc, err2 = open_svc(scm, n, SERVICE_STOP + SERVICE_QUERY_STATUS)
    if not svc then return false, err2 end
    
    local st = ffi.new("SERVICE_STATUS")
    if advapi32.ControlService(svc:get(), 1, st) == 0 then -- SERVICE_CONTROL_STOP = 1
        local err_code = kernel32.GetLastError()
        if err_code == 1062 then -- ERROR_SERVICE_NOT_ACTIVE
             return true, "Already stopped"
        end
        return false, util.last_error("ControlService failed")
    end
    
    if wait then
        return wait_logic(n, 1, timeout)
    end
    return true
end

-- [API] Set Service Configuration (Enhanced for Delayed Auto)
-- @param mode_str: "boot", "system", "auto", "demand", "disabled", "delayed-auto"
function M.set_start_mode(n, mode_str)
    local scm, err = open_scm(SC_MANAGER_CONNECT)
    if not scm then return false, err end
    local svc, err2 = open_svc(scm, n, SERVICE_CHANGE_CONFIG)
    if not svc then return false, err2 end
    
    local dwStartType
    local delayed = false
    
    local m = mode_str:lower()
    if m == "boot" then dwStartType = 0
    elseif m == "system" then dwStartType = 1
    elseif m == "auto" then dwStartType = 2
    elseif m == "demand" then dwStartType = 3
    elseif m == "disabled" then dwStartType = 4
    elseif m == "delayed-auto" then 
        dwStartType = 2 
        delayed = true
    else
        return false, "Unknown start mode: " .. tostring(mode_str)
    end
    
    -- 1. Change Standard Config
    if advapi32.ChangeServiceConfigW(svc:get(), 0xFFFFFFFF, dwStartType, 0xFFFFFFFF, nil, nil, nil, nil, nil, nil, nil) == 0 then
        return false, util.last_error("ChangeConfig failed")
    end
    
    -- 2. Handle Delayed Auto Start (Only applicable for Auto)
    if dwStartType == 2 then
        -- 使用从 advapi32 继承的结构体定义
        local info = ffi.new("SERVICE_DELAYED_AUTO_START_INFO")
        info.fDelayedAutostart = delayed and 1 or 0
        
        if advapi32.ChangeServiceConfig2W(svc:get(), SERVICE_CONFIG_DELAYED_AUTO_START_INFO, info) == 0 then
            return false, util.last_error("SetDelayedAuto failed")
        end
    end
    
    return true
end

-- [Compat] Legacy alias
M.set_config = M.set_start_mode

-- [API] Get Dependents
function M.get_dependents(n)
    local scm = open_scm(SC_MANAGER_CONNECT)
    if not scm then return {} end
    local svc = open_svc(scm, n, SERVICE_ENUMERATE_DEPENDENTS)
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

-- [API] Stop Recursive
function M.stop_recursive(n, wait, timeout)
    local deps = M.get_dependents(n)
    if deps then
        for _, dep_name in ipairs(deps) do
            M.stop_recursive(dep_name, wait, timeout)
        end
    end
    return M.stop(n, wait, timeout)
end

-- [API] Create Service (Full PECMD Feature Set)
-- @param name: Service Name
-- @param bin_path: Binary Path
-- @param opts:
--    display_name (string)
--    type (number, default 0x10)
--    start (number, default 3)
--    error_ctl (number, default 1)
--    deps (table of strings)
--    account (string)
--    password (string)
--    group (string) -> LoadOrderGroup
--    get_tag (boolean) -> Return TagId if applicable
function M.create(name, bin_path, opts)
    opts = opts or {}
    local scm, err = open_scm(SC_MANAGER_CREATE_SERVICE)
    if not scm then return false, err end
    
    local dwServiceType = opts.type or 0x10 
    local dwStartType   = opts.start or 3   
    local dwErrorControl= opts.error_ctl or 1 
    
    local lpDependencies = nil
    if opts.deps and type(opts.deps) == "table" and #opts.deps > 0 then
        local str = table.concat(opts.deps, "\0") .. "\0"
        lpDependencies = util.to_wide(str)
    end
    
    local lpLoadOrderGroup = opts.group and util.to_wide(opts.group) or nil
    local lpdwTagId = nil
    
    -- If getting a tag is requested or implied by Group + Boot/System start
    if opts.get_tag or (opts.group and (dwStartType == 0 or dwStartType == 1)) then
        lpdwTagId = ffi.new("DWORD[1]")
    end
    
    local hSvc = advapi32.CreateServiceW(
        scm:get(),
        util.to_wide(name),
        util.to_wide(opts.display_name or name),
        0xF01FF, -- SERVICE_ALL_ACCESS
        dwServiceType,
        dwStartType,
        dwErrorControl,
        util.to_wide(bin_path),
        lpLoadOrderGroup,
        lpdwTagId,
        lpDependencies,
        opts.account and util.to_wide(opts.account) or nil,
        opts.password and util.to_wide(opts.password) or nil
    )
    
    if hSvc == ffi.cast("SC_HANDLE", 0) then
        return false, util.last_error("CreateService failed")
    end
    
    local tag = (lpdwTagId ~= nil) and lpdwTagId[0] or nil
    advapi32.CloseServiceHandle(hSvc)
    
    return true, tag
end

-- [API] Delete Service
function M.delete(name)
    local scm, err = open_scm(SC_MANAGER_CONNECT)
    if not scm then return false, err end
    local svc, err2 = open_svc(scm, name, DELETE)
    if not svc then return false, err2 end
    
    if advapi32.DeleteService(svc:get()) == 0 then
        local code = kernel32.GetLastError()
        if code == 1072 then return true, "Marked for deletion" end 
        return false, util.last_error("DeleteService failed")
    end
    
    return true
end

-- [API] Wait Helper
M.wait_for_status = wait_logic

return M