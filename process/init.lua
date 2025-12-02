local ffi = require("ffi")
local bit = require("bit")
local jit = require("jit")
local util = require("win-utils.util")
local native = require("win-utils.native")

-- 0. OS Guard
if ffi.os ~= "Windows" then
    return {
        _VERSION = "3.5.4",
        _OS_SUPPORT = false,
        error = "win-utils.process only supports Windows"
    }
end

local kernel32             = require 'ffi.req' 'Windows.sdk.kernel32'
local psapi                = require 'ffi.req' 'Windows.sdk.psapi'
local advapi32             = require 'ffi.req' 'Windows.sdk.advapi32'
local ntdll                = require 'ffi.req' 'Windows.sdk.ntdll'
local user32               = require 'ffi.req' 'Windows.sdk.user32'

local C                    = ffi.C
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)

local M                    = {
    _VERSION = "3.5.4",
    _OS_SUPPORT = true,
}

M.constants                = {
    SW_HIDE                   = C.SW_HIDE,
    SW_SHOWNORMAL             = C.SW_SHOWNORMAL,
    SW_SHOW                   = C.SW_SHOW,
    PROCESS_ALL_ACCESS        = C.PROCESS_ALL_ACCESS,
    PROCESS_TERMINATE         = C.PROCESS_TERMINATE,
    PROCESS_QUERY_INFORMATION = C.PROCESS_QUERY_INFORMATION,
    SYNCHRONIZE               = C.SYNCHRONIZE,
    PROCESS_SUSPEND_RESUME    = 0x0800,
}

local findProcess, getProcessPath, getProcessCommandLine, terminateProcessTree
local _openProcessByPid, _terminateProcessByPid, _processExists
local _createProcess, _getProcessInfo
local _wait, _waitClose, _waitForExit, _setProcessPriority
local enable_debug_privilege
local _terminateProcessGracefully

-- [REFACTOR] Use Toolhelp32Snapshot for robust Process enumeration
-- NtQuerySystemInformation structure definitions can be unstable/misaligned on different OS versions
function M.list()
    local hSnap = kernel32.CreateToolhelp32Snapshot(C.TH32CS_SNAPPROCESS, 0)
    if hSnap == INVALID_HANDLE_VALUE then return {} end
    
    local pe = ffi.new("PROCESSENTRY32W")
    pe.dwSize = ffi.sizeof(pe)
    
    local processes = {}
    
    if kernel32.Process32FirstW(hSnap, pe) ~= 0 then
        repeat
            table.insert(processes, {
                pid = tonumber(pe.th32ProcessID),
                name = util.from_wide(pe.szExeFile),
                parent_pid = tonumber(pe.th32ParentProcessID),
                thread_count = tonumber(pe.cntThreads),
                -- Toolhelp does not provide detailed memory/IO stats in one go
                -- For those, specific queries via GetProcessMemoryInfo are needed
            })
        until kernel32.Process32NextW(hSnap, pe) == 0
    end
    
    kernel32.CloseHandle(hSnap)
    return processes
end

findProcess = function(name_or_pid)
    if not name_or_pid then return 0 end
    local target_pid = tonumber(name_or_pid)
    
    local procs = M.list()
    local target_lower = nil
    if not target_pid then target_lower = name_or_pid:lower() end
    
    for _, p in ipairs(procs) do
        if target_pid then
            if p.pid == target_pid then return p.pid end
        elseif target_lower then
            if p.name:lower() == target_lower then return p.pid end
        end
    end
    return 0
end

getProcessPath = function(pid, buffer, buffer_size, process_handle)
    local h_proc = process_handle
    local needs_close = false

    if not h_proc then
        h_proc = kernel32.OpenProcess(C.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
        if h_proc == nil or h_proc == INVALID_HANDLE_VALUE then return 0 end
        needs_close = true
    end

    local path_length_ptr = ffi.new("DWORD[1]", buffer_size)
    local res = kernel32.QueryFullProcessImageNameW(h_proc, 0, buffer, path_length_ptr)

    if res == 0 then
        local path_length = psapi.GetModuleFileNameExW(h_proc, nil, buffer, buffer_size)
        if path_length > 0 then
            path_length_ptr[0] = path_length
            res = 1
        end
    end

    if needs_close then kernel32.CloseHandle(h_proc) end

    return res ~= 0 and path_length_ptr[0] or 0
end

getProcessCommandLine = function(pid, buffer, buffer_size)
    buffer[0] = 0
    local h_proc = kernel32.OpenProcess(bit.bor(C.PROCESS_QUERY_INFORMATION, C.PROCESS_VM_READ), false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then return false end

    local function close_and_return(ret)
        kernel32.CloseHandle(h_proc)
        return ret
    end

    local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
    if ntdll.NtQueryInformationProcess(h_proc, 0, pbi, ffi.sizeof(pbi), nil) ~= 0 then return close_and_return(false) end
    if pbi.PebBaseAddress == nil then return close_and_return(false) end

    local peb = ffi.new("PEB")
    if kernel32.ReadProcessMemory(h_proc, pbi.PebBaseAddress, peb, ffi.sizeof(peb), nil) == 0 then
        return close_and_return(false)
    end
    if peb.ProcessParameters == nil then return close_and_return(false) end

    local params = ffi.new("RTL_USER_PROCESS_PARAMETERS")
    if kernel32.ReadProcessMemory(h_proc, peb.ProcessParameters, params, ffi.sizeof(params), nil) == 0 then
        return close_and_return(false)
    end

    if params.CommandLine.Length > 0 then
        local bytes_to_read = params.CommandLine.Length > (buffer_size - 1) * 2 and (buffer_size - 1) * 2 or
            params.CommandLine.Length
        if kernel32.ReadProcessMemory(h_proc, params.CommandLine.Buffer, buffer, bytes_to_read, nil) ~= 0 then
            buffer[bytes_to_read / 2] = 0
            return close_and_return(true)
        end
    end
    return close_and_return(false)
end

_terminateProcessByPid = function(pid, exit_code)
    if pid == 0 then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return false
    end
    local h_proc = kernel32.OpenProcess(C.PROCESS_TERMINATE, false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then return false end
    local res = kernel32.TerminateProcess(h_proc, exit_code or 0)
    kernel32.CloseHandle(h_proc)
    return res ~= 0
end

_terminateProcessGracefully = function(pid, timeout_ms)
    timeout_ms = timeout_ms or 3000
    jit.off()
    local h_proc = kernel32.OpenProcess(bit.bor(C.SYNCHRONIZE, C.PROCESS_TERMINATE), false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then
        jit.on(); return false
    end

    local pid_ptr = ffi.new("DWORD[1]")
    local function enum_func(hwnd, lParam)
        user32.GetWindowThreadProcessId(hwnd, pid_ptr)
        if pid_ptr[0] == pid then
            user32.PostMessageW(hwnd, user32.WM_CLOSE, 0, 0)
        end
        return 1
    end

    local cb = ffi.cast("WNDENUMPROC", enum_func)
    local anchor = { cb }
    user32.EnumWindows(cb, 0)
    cb:free()
    anchor = nil

    local res = kernel32.WaitForSingleObject(h_proc, timeout_ms)
    local success = true
    if res == C.WAIT_TIMEOUT then
        success = (kernel32.TerminateProcess(h_proc, 0) ~= 0)
    end
    kernel32.CloseHandle(h_proc)
    jit.on()
    return success
end

enable_debug_privilege = function()
    local token_lib = require("win-utils.process.token")
    return token_lib.enable_privilege("SeDebugPrivilege")
end

terminateProcessTree = function(pid)
    if not M._privilege_enabled then M._privilege_enabled = enable_debug_privilege() end
    
    local all_procs = M.list()
    local children = {}
    
    for _, p in ipairs(all_procs) do
        if p.parent_pid == pid then
            table.insert(children, p.pid)
        end
    end
    
    for _, child_pid in ipairs(children) do terminateProcessTree(child_pid) end
    _terminateProcessByPid(pid, 1)
end

_openProcessByPid = function(pid, desired_access)
    if pid == 0 then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return nil
    end
    local h_proc = kernel32.OpenProcess(desired_access, false, pid)
    return (h_proc ~= nil and h_proc ~= INVALID_HANDLE_VALUE) and h_proc or nil
end

_processExists = function(process_name_or_pid)
    if not process_name_or_pid or process_name_or_pid == "" then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return 0
    end
    return findProcess(process_name_or_pid)
end

local function _findAllProcesses(process_name)
    local procs = M.list()
    local pids = {}
    local target_lower = process_name:lower()
    
    for _, p in ipairs(procs) do
        if p.name:lower() == target_lower then
            table.insert(pids, p.pid)
        end
    end
    return pids
end

_createProcess = function(command, working_dir, show_mode, desktop_name)
    local si = ffi.new("STARTUPINFOW"); si.cb = ffi.sizeof(si)
    si.dwFlags, si.wShowWindow = C.STARTF_USESHOWWINDOW, show_mode or M.constants.SW_SHOW
    
    local desktop_w = nil
    if desktop_name and desktop_name ~= "" then 
        desktop_w = util.to_wide(desktop_name)
        si.lpDesktop = desktop_w 
    end
    
    local pi = ffi.new("PROCESS_INFORMATION")
    local cmd_buffer_w = util.to_wide(command)
    local wd_wstr = util.to_wide(working_dir)
    
    if kernel32.CreateProcessW(nil, cmd_buffer_w, nil, nil, false, 0, nil, wd_wstr, si, pi) == 0 then
        return nil, nil, kernel32.GetLastError()
    end
    kernel32.CloseHandle(pi.hThread)
    return pi.dwProcessId, pi.hProcess, 0
end

_getProcessInfo = function(pid)
    if pid == 0 then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return nil
    end
    local out_info = { pid = pid }
    local h_proc = kernel32.OpenProcess(bit.bor(C.PROCESS_QUERY_INFORMATION, C.PROCESS_VM_READ), false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then return nil end

    local found = false
    local exit_code = ffi.new("DWORD[1]")
    if kernel32.GetExitCodeProcess(h_proc, exit_code) ~= 0 and exit_code[0] == 259 then
        found = true
        local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
        if ntdll.NtQueryInformationProcess(h_proc, 0, pbi, ffi.sizeof(pbi), nil) == 0 then
            out_info.parent_pid = tonumber(pbi.InheritedFromUniqueProcessId)
        end
    end
    
    if not found then
        kernel32.CloseHandle(h_proc); return nil
    end

    local session_id_ptr = ffi.new("DWORD[1]")
    if kernel32.ProcessIdToSessionId(pid, session_id_ptr) ~= 0 then out_info.session_id = session_id_ptr[0] else out_info.session_id = -1 end
    local pmc = ffi.new("PROCESS_MEMORY_COUNTERS_EX"); pmc.cb = ffi.sizeof(pmc)
    if psapi.GetProcessMemoryInfo(h_proc, pmc, ffi.sizeof(pmc)) ~= 0 then
        out_info.memory_usage_bytes = tonumber(pmc.WorkingSetSize)
    else
        out_info.memory_usage_bytes = 0
    end
    local path_buf = ffi.new("WCHAR[260]")
    if getProcessPath(pid, path_buf, 260, h_proc) > 0 then
        out_info.exe_path = util.from_wide(path_buf)
    else
        out_info.exe_path = ""
    end
    local cmd_buf = ffi.new("WCHAR[2048]")
    if getProcessCommandLine(pid, cmd_buf, 2048) then
        out_info.command_line = util.from_wide(cmd_buf)
    else
        out_info.command_line = ""
    end
    kernel32.CloseHandle(h_proc)
    return out_info
end

_waitForExit = function(process_handle, timeout_ms)
    if process_handle == nil or process_handle == INVALID_HANDLE_VALUE then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return false
    end
    local res = kernel32.WaitForSingleObject(process_handle, timeout_ms < 0 and C.INFINITE or timeout_ms)
    if res == C.WAIT_TIMEOUT then kernel32.SetLastError(C.WAIT_TIMEOUT) end
    return res == C.WAIT_OBJECT_0
end

_setProcessPriority = function(pid, priority)
    local pmap = {
        L = C.IDLE_PRIORITY_CLASS,
        B = C.BELOW_NORMAL_PRIORITY_CLASS,
        N = C.NORMAL_PRIORITY_CLASS,
        A = C.ABOVE_NORMAL_PRIORITY_CLASS,
        H = C.HIGH_PRIORITY_CLASS,
        R = C.REALTIME_PRIORITY_CLASS
    }
    local pclass = pmap[priority and priority:upper() or ""]
    if not pclass then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return false
    end
    if not pid or pid == 0 then
        kernel32.SetLastError(C.ERROR_NOT_FOUND); return false
    end
    local h_proc = kernel32.OpenProcess(C.PROCESS_SET_INFORMATION, false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then return false end
    local res = kernel32.SetPriorityClass(h_proc, pclass)
    kernel32.CloseHandle(h_proc)
    return res ~= 0
end

-- [NEW] Native Suspend Helper
local function _suspendProcess(pid)
    if pid == 0 then return false, "Invalid PID" end
    -- Need PROCESS_SUSPEND_RESUME access
    local h_proc = kernel32.OpenProcess(M.constants.PROCESS_SUSPEND_RESUME, false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then 
        return false, util.format_error() 
    end
    
    local status = ntdll.NtSuspendProcess(h_proc)
    kernel32.CloseHandle(h_proc)
    
    if status < 0 then return false, string.format("NtSuspendProcess failed: 0x%X", status) end
    return true
end

-- [NEW] Native Resume Helper
local function _resumeProcess(pid)
    if pid == 0 then return false, "Invalid PID" end
    local h_proc = kernel32.OpenProcess(M.constants.PROCESS_SUSPEND_RESUME, false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then 
        return false, util.format_error() 
    end
    
    local status = ntdll.NtResumeProcess(h_proc)
    kernel32.CloseHandle(h_proc)
    
    if status < 0 then return false, string.format("NtResumeProcess failed: 0x%X", status) end
    return true
end

_wait = function(process_name, timeout_ms)
    if not process_name or process_name == "" then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return 0
    end
    local start = ffi.C.GetTickCount64()
    timeout_ms = timeout_ms or -1
    while true do
        local pid = findProcess(process_name)
        if pid > 0 then return pid end
        if timeout_ms >= 0 and (ffi.C.GetTickCount64() - start) >= timeout_ms then
            kernel32.SetLastError(C.WAIT_TIMEOUT); return 0
        end
        ffi.C.Sleep(100)
    end
end

local Process = {}
Process.__index = Process
local function new_process(pid, handle) return setmetatable({ pid = pid, _handle = handle }, Process) end
function Process:__gc()
    if self._handle and self._handle ~= INVALID_HANDLE_VALUE then
        kernel32.CloseHandle(self._handle); self._handle = nil
    end
end

function Process:close()
    if self._handle and self._handle ~= INVALID_HANDLE_VALUE then
        kernel32.CloseHandle(self._handle); self._handle = nil; return true
    end
    return false
end

function M.exec(command, working_dir, show_mode, desktop_name)
    local pid, handle, err = _createProcess(command, working_dir, show_mode, desktop_name); if pid and pid > 0 then
        return new_process(pid, handle)
    end
    return nil, err, util.format_error(err)
end

function M.open_by_pid(pid, access)
    access = access or M.constants.PROCESS_ALL_ACCESS; local handle = _openProcessByPid(pid, access); if handle then
        return new_process(pid, handle)
    end; local err = kernel32.GetLastError(); return nil, err, util.format_error(err)
end

function M.open_by_name(name, access)
    access = access or M.constants.PROCESS_ALL_ACCESS; local pid = _processExists(name); if pid > 0 then
        return M.open_by_pid(pid, access)
    end; local err = kernel32.GetLastError(); if err == 0 then err = C.ERROR_NOT_FOUND end; return
        nil, err, util.format_error(err)
end

function M.current() return M.open_by_pid(kernel32.GetCurrentProcessId()) end

function Process:is_valid() return self._handle and self._handle ~= INVALID_HANDLE_VALUE end

function Process:handle() return self._handle end

function Process:terminate(exit_code)
    exit_code = exit_code or 0; if self:is_valid() and kernel32.TerminateProcess(self._handle, exit_code) ~= 0 then return true end; if not _terminateProcessByPid(self.pid, exit_code) then
        local err = kernel32.GetLastError(); return nil, err, util.format_error(err)
    end
    return true
end

function Process:suspend()
    if self:is_valid() then
        -- Try with existing handle if it has rights (unlikely if opened generic)
        local status = ntdll.NtSuspendProcess(self._handle)
        if status >= 0 then return true end
    end
    -- Fallback to opening new handle with specific rights
    return _suspendProcess(self.pid)
end

function Process:resume()
    if self:is_valid() then
        local status = ntdll.NtResumeProcess(self._handle)
        if status >= 0 then return true end
    end
    return _resumeProcess(self.pid)
end

function Process:terminate_tree()
    terminateProcessTree(self.pid); return true
end

function Process:wait_for_exit(timeout_ms) return _waitForExit(self._handle, timeout_ms or -1) end

function Process:get_info()
    local info = _getProcessInfo(self.pid); if info then return info end; local err = kernel32.GetLastError(); return nil,
        err, util.format_error(err)
end

function Process:get_path()
    local b = ffi.new("WCHAR[260]"); if getProcessPath(self.pid, b, 260, self._handle) > 0 then return util.from_wide(b) end; local err =
        kernel32.GetLastError(); return nil, err, util.format_error(err)
end

function Process:get_command_line()
    local b = ffi.new("WCHAR[2048]"); if getProcessCommandLine(self.pid, b, 2048) then return util.from_wide(b) end; local err =
        kernel32.GetLastError(); return nil, err, util.format_error(err)
end

function Process:set_priority(p)
    if not _setProcessPriority(self.pid, p) then
        local err = kernel32.GetLastError(); return nil, err, util.format_error(err)
    end
    return true
end

function M.find_all(n)
    local pids = _findAllProcesses(n); 
    if not pids or #pids == 0 then return {} end
    return pids
end

function M.exists(n) return _processExists(n) end

function M.terminate_by_pid(p, e) return _terminateProcessByPid(p, e or 0) end

function M.terminate_gracefully(p, t) return _terminateProcessGracefully(p, t) end

function M.suspend(pid) return _suspendProcess(pid) end
function M.resume(pid) return _resumeProcess(pid) end

function M.wait(n, t)
    local p = _wait(n, t); if p > 0 then return p end; local e = kernel32.GetLastError(); if e == 0 then
        e = C.WAIT_TIMEOUT
    end; return nil, e, util.format_error(e)
end

function M.wait_close(n, t)
    if not n or n == "" then return false end; local pid = findProcess(n); if pid == 0 then return true end; local h =
        _openProcessByPid(pid, C.SYNCHRONIZE); if not h then return false end; local r = _waitForExit(h, t or -1); kernel32
        .CloseHandle(h); return r
end

M.enable_privilege = enable_debug_privilege
M.enable_privilege()

return M