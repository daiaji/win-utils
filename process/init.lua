local ffi = require("ffi")
local bit = require("bit")
local jit = require("jit")
local util = require("win-utils.util")

-- 0. OS Guard
if ffi.os ~= "Windows" then
    return {
        _VERSION = "3.5.4",
        _OS_SUPPORT = false,
        error = "win-utils.process only supports Windows"
    }
end

-- 1. Load Libraries via standard ffi.req
local kernel32             = require 'ffi.req' 'Windows.sdk.kernel32'
local psapi                = require 'ffi.req' 'Windows.sdk.psapi'
local advapi32             = require 'ffi.req' 'Windows.sdk.advapi32'
local wtsapi32             = require 'ffi.req' 'Windows.sdk.wtsapi32'
local userenv              = require 'ffi.req' 'Windows.sdk.userenv'
local ntdll                = require 'ffi.req' 'Windows.sdk.ntdll'
local user32               = require 'ffi.req' 'Windows.sdk.user32'

local C                    = ffi.C
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)

local M                    = {
    _VERSION = "3.5.4",
    _OS_SUPPORT = true,
}

-- Public Constants
M.constants                = {
    SW_HIDE                   = C.SW_HIDE,
    SW_SHOWNORMAL             = C.SW_SHOWNORMAL,
    SW_SHOW                   = C.SW_SHOW,
    PROCESS_ALL_ACCESS        = C.PROCESS_ALL_ACCESS,
    PROCESS_TERMINATE         = C.PROCESS_TERMINATE,
    PROCESS_QUERY_INFORMATION = C.PROCESS_QUERY_INFORMATION,
    SYNCHRONIZE               = C.SYNCHRONIZE,
}

-- Forward declarations
local findProcess, getProcessPath, getProcessCommandLine, terminateProcessTree
local _openProcessByPid, _terminateProcessByPid, _processExists, _findAllProcesses
local _createProcess, _createProcessAsSystem, _getProcessInfo
local _wait, _waitClose, _waitForExit, _setProcessPriority
local enable_debug_privilege
local _terminateProcessGracefully

-- [OPTIMIZATION] Pre-compile struct type for repeated use
local PROCESSENTRY32W_T    = ffi.typeof("PROCESSENTRY32W")

local function create_snapshot()
    local h = kernel32.CreateToolhelp32Snapshot(C.TH32CS_SNAPPROCESS, 0)
    if h == INVALID_HANDLE_VALUE then return nil end
    return h
end

findProcess = function(name_or_pid)
    if not name_or_pid then return 0 end
    local target_pid = tonumber(name_or_pid)
    local target_w = nil

    if not target_pid then
        target_w = util.to_wide(name_or_pid, true) -- Use scratch buffer
    end

    local h_snap = create_snapshot()
    if not h_snap then return 0 end

    local pe = PROCESSENTRY32W_T()
    pe.dwSize = ffi.sizeof(pe)

    local found_pid = 0

    if kernel32.Process32FirstW(h_snap, pe) ~= 0 then
        repeat
            if target_pid then
                if pe.th32ProcessID == target_pid then
                    found_pid = pe.th32ProcessID
                    break
                end
            elseif target_w then
                if kernel32.lstrcmpiW(pe.szExeFile, target_w) == 0 then
                    found_pid = pe.th32ProcessID
                    break
                end
            end
        until kernel32.Process32NextW(h_snap, pe) == 0
    end

    kernel32.CloseHandle(h_snap)
    return found_pid
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
        return
            close_and_return(false)
    end
    if peb.ProcessParameters == nil then return close_and_return(false) end

    local params = ffi.new("RTL_USER_PROCESS_PARAMETERS")
    if kernel32.ReadProcessMemory(h_proc, peb.ProcessParameters, params, ffi.sizeof(params), nil) == 0 then
        return
            close_and_return(false)
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
    -- [SAFETY] Manual JIT off for callback safety (per LuaJIT docs on callbacks)
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
    -- [SAFETY] Anchor the callback
    local anchor = { cb }
    user32.EnumWindows(cb, 0)
    cb:free()
    anchor = nil -- release anchor

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
    local hToken = ffi.new("HANDLE[1]")
    local hProcess = ffi.cast("HANDLE", -1)

    if advapi32.OpenProcessToken(hProcess, bit.bor(C.TOKEN_ADJUST_PRIVILEGES, C.TOKEN_QUERY), hToken) == 0 then
        return false, kernel32.GetLastError()
    end

    local token_handle = hToken[0]
    local luid = ffi.new("LUID")
    local se_debug_name = util.to_wide("SeDebugPrivilege")

    if advapi32.LookupPrivilegeValueW(nil, se_debug_name, luid) == 0 then
        kernel32.CloseHandle(token_handle)
        return false, kernel32.GetLastError()
    end

    local tp = ffi.new("TOKEN_PRIVILEGES")
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = C.SE_PRIVILEGE_ENABLED

    if advapi32.AdjustTokenPrivileges(token_handle, 0, tp, ffi.sizeof(tp), nil, nil) == 0 then
        kernel32.CloseHandle(token_handle)
        return false, kernel32.GetLastError()
    end

    kernel32.CloseHandle(token_handle)
    if kernel32.GetLastError() == 1300 then return false, 1300 end
    return true
end

terminateProcessTree = function(pid)
    if not M._privilege_enabled then M._privilege_enabled = enable_debug_privilege() end
    local children = {}
    local h_snap = create_snapshot()
    if h_snap then
        local pe = PROCESSENTRY32W_T()
        pe.dwSize = ffi.sizeof(pe)
        if kernel32.Process32FirstW(h_snap, pe) ~= 0 then
            repeat
                if pe.th32ParentProcessID == pid then table.insert(children, pe.th32ProcessID) end
            until kernel32.Process32NextW(h_snap, pe) == 0
        end
        kernel32.CloseHandle(h_snap)
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

_findAllProcesses = function(process_name, out_pids, pids_array_size)
    if not process_name or process_name == "" or (not out_pids and pids_array_size > 0) then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return -1
    end
    local target_w = util.to_wide(process_name, true)
    local h_snap = create_snapshot()
    if not h_snap then return -1 end

    local found_count, stored_count = 0, 0
    local pe = PROCESSENTRY32W_T()
    pe.dwSize = ffi.sizeof(pe)
    if kernel32.Process32FirstW(h_snap, pe) ~= 0 then
        repeat
            if kernel32.lstrcmpiW(pe.szExeFile, target_w) == 0 then
                if out_pids and stored_count < pids_array_size then
                    out_pids[stored_count] = pe.th32ProcessID
                    stored_count = stored_count + 1
                end
                found_count = found_count + 1
            end
        until kernel32.Process32NextW(h_snap, pe) == 0
    end
    kernel32.CloseHandle(h_snap)
    return out_pids and stored_count or found_count
end

_createProcess = function(command, working_dir, show_mode, desktop_name)
    local si = ffi.new("STARTUPINFOW"); si.cb = ffi.sizeof(si)
    si.dwFlags, si.wShowWindow = C.STARTF_USESHOWWINDOW, show_mode or M.constants.SW_SHOW
    
    -- [FIX] GC Anchoring: Keep reference to desktop_name wide string
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

_createProcessAsSystem = function(command, working_dir, show_mode)
    local last_error
    local pid, proc_handle = nil, nil
    repeat
        if not command or command == "" then
            last_error = C.ERROR_INVALID_PARAMETER; break
        end

        local session_id = kernel32.WTSGetActiveConsoleSessionId()
        if session_id == 0xFFFFFFFF then
            last_error = kernel32.GetLastError(); if last_error == 0 then last_error = 1008 end; break
        end

        local user_token_ptr = ffi.new("HANDLE[1]")
        if wtsapi32.WTSQueryUserToken(session_id, user_token_ptr) == 0 then
            last_error = kernel32.GetLastError(); if last_error == 0 then last_error = 1008 end; break
        end
        local user_token = user_token_ptr[0]

        local primary_token_ptr = ffi.new("HANDLE[1]")
        if advapi32.DuplicateTokenEx(user_token, C.MAXIMUM_ALLOWED, nil, 1, 1, primary_token_ptr) == 0 then
            last_error = kernel32.GetLastError(); if last_error == 0 then last_error = 5 end; kernel32.CloseHandle(
                user_token); break
        end
        local primary_token = primary_token_ptr[0]

        local env_block_ptr = ffi.new("PVOID[1]")
        if userenv.CreateEnvironmentBlock(env_block_ptr, primary_token, false) == 0 then
            last_error = kernel32.GetLastError(); if last_error == 0 then last_error = 1157 end; kernel32.CloseHandle(
                primary_token); kernel32.CloseHandle(user_token); break
        end
        local env_block = env_block_ptr[0]

        local si = ffi.new("STARTUPINFOW"); si.cb = ffi.sizeof(si)
        si.dwFlags, si.wShowWindow = C.STARTF_USESHOWWINDOW, show_mode or M.constants.SW_SHOW
        
        -- [FIX] GC Anchoring: default desktop string
        local desktop_w = util.to_wide("winsta0\\default")
        si.lpDesktop = desktop_w
        
        local pi = ffi.new("PROCESS_INFORMATION")
        local cmd_buffer_w = util.to_wide(command)
        local wd_wstr = util.to_wide(working_dir)

        if advapi32.CreateProcessAsUserW(primary_token, nil, cmd_buffer_w, nil, nil, false, C.CREATE_UNICODE_ENVIRONMENT, env_block, wd_wstr, si, pi) == 0 then
            last_error = kernel32.GetLastError(); if last_error == 0 then last_error = 1157 end
        else
            kernel32.CloseHandle(pi.hThread)
            pid, proc_handle, last_error = pi.dwProcessId, pi.hProcess, 0
        end

        userenv.DestroyEnvironmentBlock(env_block)
        kernel32.CloseHandle(primary_token)
        kernel32.CloseHandle(user_token)
    until true

    if last_error and last_error ~= 0 then kernel32.SetLastError(last_error) end
    return pid, proc_handle, last_error
end

_getProcessInfo = function(pid)
    if pid == 0 then
        kernel32.SetLastError(C.ERROR_INVALID_PARAMETER); return nil
    end
    local out_info = { pid = pid }
    local h_proc = kernel32.OpenProcess(bit.bor(C.PROCESS_QUERY_INFORMATION, C.PROCESS_VM_READ), false, pid)
    if not h_proc or h_proc == INVALID_HANDLE_VALUE then return nil end

    local found = false
    local h_snap = create_snapshot()
    if h_snap then
        local pe = PROCESSENTRY32W_T()
        pe.dwSize = ffi.sizeof(pe)
        if kernel32.Process32FirstW(h_snap, pe) ~= 0 then
            repeat
                if pe.th32ProcessID == pid then
                    out_info.parent_pid = pe.th32ParentProcessID
                    out_info.thread_count = pe.cntThreads
                    found = true
                    break
                end
            until kernel32.Process32NextW(h_snap, pe) == 0
        end
        kernel32.CloseHandle(h_snap)
    end
    if not found then
        kernel32.CloseHandle(h_proc); return nil
    end

    local session_id_ptr = ffi.new("DWORD[1]")
    if kernel32.ProcessIdToSessionId(pid, session_id_ptr) ~= 0 then out_info.session_id = session_id_ptr[0] else out_info.session_id = -1 end
    local pmc = ffi.new("PROCESS_MEMORY_COUNTERS_EX"); pmc.cb = ffi.sizeof(pmc)
    if psapi.GetProcessMemoryInfo(h_proc, pmc, ffi.sizeof(pmc)) ~= 0 then
        out_info.memory_usage_bytes = tonumber(pmc
            .WorkingSetSize)
    else
        out_info.memory_usage_bytes = 0
    end
    local path_buf = ffi.new("WCHAR[260]")
    if getProcessPath(pid, path_buf, 260, h_proc) > 0 then
        out_info.exe_path = util.from_wide(path_buf)
    else
        out_info.exe_path =
        ""
    end
    local cmd_buf = ffi.new("WCHAR[2048]")
    if getProcessCommandLine(pid, cmd_buf, 2048) then
        out_info.command_line = util.from_wide(cmd_buf)
    else
        out_info.command_line =
        ""
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
        A = C
            .ABOVE_NORMAL_PRIORITY_CLASS,
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
        return
            new_process(pid, handle)
    end
    return nil, err, util.format_error(err)
end

function M.exec_as_system(command, working_dir, show_mode)
    local pid, handle, err = _createProcessAsSystem(command, working_dir, show_mode); if pid and pid > 0 then
        return
            new_process(pid, handle)
    end
    return nil, err, util.format_error(err)
end

function M.open_by_pid(pid, access)
    access = access or M.constants.PROCESS_ALL_ACCESS; local handle = _openProcessByPid(pid, access); if handle then
        return
            new_process(pid, handle)
    end; local err = kernel32.GetLastError(); return nil, err, util.format_error(err)
end

function M.open_by_name(name, access)
    access = access or M.constants.PROCESS_ALL_ACCESS; local pid = _processExists(name); if pid > 0 then
        return M
            .open_by_pid(pid, access)
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
    local c = _findAllProcesses(n, nil, 0); if c < 0 then
        local e = kernel32.GetLastError(); return nil, e, util.format_error(e)
    end; if c == 0 then return {} end; local b = ffi.new("DWORD[?]", c); local s = _findAllProcesses(n, b, c); local p = {}; for i = 0, s - 1 do
        p[i + 1] =
            b[i]
    end
    return p
end

function M.exists(n) return _processExists(n) end

function M.terminate_by_pid(p, e) return _terminateProcessByPid(p, e or 0) end

function M.terminate_gracefully(p, t) return _terminateProcessGracefully(p, t) end

function M.wait(n, t)
    local p = _wait(n, t); if p > 0 then return p end; local e = kernel32.GetLastError(); if e == 0 then
        e = C
            .WAIT_TIMEOUT
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