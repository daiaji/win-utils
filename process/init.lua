local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local psapi = require 'ffi.req' 'Windows.sdk.psapi'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local class = require 'win-utils.deps'.class
local table_new = require 'table.new'
local table_ext = require 'ext.table'
local jit = require 'jit' 
local token = require 'win-utils.process.token' 

local M = {}

-- Lazy load
local sub_modules = {
    token   = 'win-utils.process.token',
    job     = 'win-utils.process.job',
    memory  = 'win-utils.process.memory',
    module  = 'win-utils.process.module',
    handles = 'win-utils.process.handles'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

M.constants = {
    SW_HIDE=0, SW_SHOWNORMAL=1, SW_SHOW=5, 
    PROCESS_ALL_ACCESS=0x1F0FFF, PROCESS_TERMINATE=1, PROCESS_QUERY_INFORMATION=0x400, 
    PROCESS_SET_INFORMATION=0x200,
    SYNCHRONIZE=0x100000, PROCESS_SUSPEND_RESUME=0x0800
}

local INVALID_HANDLE = ffi.cast("HANDLE", -1)

local PRIORITY_MAP = {
    L = 0x40, B = 0x4000, N = 0x20, A = 0x8000, H = 0x80, R = 0x100
}

local function get_cmd_line(pid)
    local hProc = kernel32.OpenProcess(0x410, false, pid)
    if not hProc or hProc == INVALID_HANDLE then return "" end
    
    local cmd = ""
    local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
    if ntdll.NtQueryInformationProcess(hProc, 0, pbi, ffi.sizeof(pbi), nil) >= 0 and pbi.PebBaseAddress ~= nil then
        local peb = ffi.new("PEB")
        if kernel32.ReadProcessMemory(hProc, pbi.PebBaseAddress, peb, ffi.sizeof(peb), nil) ~= 0 then
            local params = ffi.new("RTL_USER_PROCESS_PARAMETERS")
            if kernel32.ReadProcessMemory(hProc, peb.ProcessParameters, params, ffi.sizeof(params), nil) ~= 0 then
                local len = params.CommandLine.Length
                if len > 0 then
                    local buf = ffi.new("uint8_t[?]", len + 2)
                    if kernel32.ReadProcessMemory(hProc, params.CommandLine.Buffer, buf, len, nil) ~= 0 then
                        cmd = util.from_wide(ffi.cast("wchar_t*", buf), len/2)
                    end
                end
            end
        end
    end
    kernel32.CloseHandle(hProc)
    return cmd
end

local function get_path(pid, handle)
    local h = handle
    local close_me = false
    if not h then 
        h = kernel32.OpenProcess(0x1000, false, pid)
        if not h or h == INVALID_HANDLE then return "" end
        close_me = true
    end
    local buf = ffi.new("wchar_t[1024]")
    local sz = ffi.new("DWORD[1]", 1024)
    local path = ""
    if kernel32.QueryFullProcessImageNameW(h, 0, buf, sz) ~= 0 then path = util.from_wide(buf) end
    if close_me then kernel32.CloseHandle(h) end
    return path
end

local Process = class()

function Process:init(pid, h) 
    self.pid = pid
    self.obj = Handle(h)
end

function Process:handle() return self.obj:get() end
function Process:close() self.obj:close() end

function Process:terminate(code) 
    if kernel32.TerminateProcess(self:handle(), code or 0) == 0 then
        return false, util.last_error("TerminateProcess failed")
    end
    return true
end

function Process:suspend() return ntdll.NtSuspendProcess(self:handle()) >= 0 end
function Process:resume() return ntdll.NtResumeProcess(self:handle()) >= 0 end
function Process:wait(ms) return kernel32.WaitForSingleObject(self:handle(), ms or -1) == 0 end
function Process:wait_input(ms) return user32.WaitForInputIdle(self:handle(), ms or -1) == 0 end

function Process:get_path() return get_path(self.pid, self:handle()) end
function Process:get_command_line() return get_cmd_line(self.pid) end

function Process:set_priority(mode)
    local val = PRIORITY_MAP[mode and mode:upper() or "N"]
    if not val then return false, "Invalid priority" end
    local h = self:handle()
    local temp_h = nil
    if not kernel32.SetPriorityClass(h, val) then
        temp_h = kernel32.OpenProcess(M.constants.PROCESS_SET_INFORMATION, false, self.pid)
        if not temp_h then return false, util.last_error("Access denied") end
        h = temp_h
    end
    local res = kernel32.SetPriorityClass(h, val) ~= 0
    if temp_h then kernel32.CloseHandle(temp_h) end
    return res
end

function Process:get_info()
    if self.pid == 0 then return nil end
    local info = { pid = self.pid }
    local h = self:handle() 
    local temp_h = nil
    if not h then 
        h = kernel32.OpenProcess(0x410, false, self.pid)
        temp_h = h
    end
    if h and h ~= INVALID_HANDLE then
        local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
        if ntdll.NtQueryInformationProcess(h, 0, pbi, ffi.sizeof(pbi), nil) >= 0 then
            info.parent_pid = tonumber(pbi.InheritedFromUniqueProcessId)
        end
        local pmc = ffi.new("PROCESS_MEMORY_COUNTERS_EX"); pmc.cb = ffi.sizeof(pmc)
        if psapi.GetProcessMemoryInfo(h, pmc, ffi.sizeof(pmc)) ~= 0 then
            info.memory_usage_bytes = tonumber(pmc.WorkingSetSize)
        end
        local sess = ffi.new("DWORD[1]")
        if kernel32.ProcessIdToSessionId(self.pid, sess) ~= 0 then info.session_id = sess[0] end
        info.exe_path = get_path(self.pid, h)
        if temp_h then kernel32.CloseHandle(temp_h) end
    end
    info.command_line = get_cmd_line(self.pid)
    return info
end

function Process:kill(mode) return M.kill(self.pid, mode) end

function M.exec(cmd, workdir, show)
    local si = ffi.new("STARTUPINFOW"); si.cb = ffi.sizeof(si); si.dwFlags = 1; si.wShowWindow = show or 1
    local pi = ffi.new("PROCESS_INFORMATION")
    if kernel32.CreateProcessW(nil, util.to_wide(cmd), nil, nil, false, 0, nil, util.to_wide(workdir), si, pi) == 0 then 
        return nil, util.last_error()
    end
    kernel32.CloseHandle(pi.hThread)
    return Process(tonumber(pi.dwProcessId), pi.hProcess)
end

function M.open(pid, access)
    access = access or 0x1F0FFF -- PROCESS_ALL_ACCESS
    local h = kernel32.OpenProcess(access, false, pid)
    
    if not h then
        local err = kernel32.GetLastError()
        if err == 5 then 
            if token.enable_privilege("SeDebugPrivilege") then
                h = kernel32.OpenProcess(access, false, pid)
            end
        end
    end
    
    if not h then return nil, util.last_error() end
    return Process(pid, h)
end

function M.current() return M.open(kernel32.GetCurrentProcessId()) end

function M.each()
    local hSnap = kernel32.CreateToolhelp32Snapshot(2, 0)
    if hSnap == INVALID_HANDLE then return function() end end
    local safe_snap = Handle(hSnap)
    local pe = ffi.new("PROCESSENTRY32W"); pe.dwSize = ffi.sizeof(pe)
    local first = true
    return function()
        if not safe_snap:valid() then return nil end
        local res
        if first then res = kernel32.Process32FirstW(safe_snap:get(), pe); first = false
        else res = kernel32.Process32NextW(safe_snap:get(), pe) end
        if res == 0 then safe_snap:close(); return nil end
        return { 
            pid = tonumber(pe.th32ProcessID), 
            name = util.from_wide(pe.szExeFile), 
            parent_pid = tonumber(pe.th32ParentProcessID), 
            thread_count = tonumber(pe.cntThreads) 
        }
    end
end

function M.list() 
    local t = table_new(256, 0)
    setmetatable(t, { __index = table_ext })
    for p in M.each() do table.insert(t, p) end 
    return t 
end

function M.exists(pid)
    if type(pid) ~= "number" then 
        local target = pid:lower()
        for p in M.each() do if p.name:lower() == target then return p.pid end end 
        return 0 
    end
    
    local h = kernel32.OpenProcess(0x100000, false, pid)
    if h and h ~= INVALID_HANDLE then
        local r = kernel32.WaitForSingleObject(h, 0)
        kernel32.CloseHandle(h)
        return (r == 258) and pid or 0
    end
    h = kernel32.OpenProcess(0x1000, false, pid)
    if h and h ~= INVALID_HANDLE then
        local c = ffi.new("DWORD[1]")
        local ok = (kernel32.GetExitCodeProcess(h, c) ~= 0 and c[0] == 259)
        kernel32.CloseHandle(h)
        return ok and pid or 0
    end
    return 0
end

function M.find_all(name)
    local res = {}
    local target = name:lower()
    for p in M.each() do
        if p.name:lower() == target then table.insert(res, p.pid) end
    end
    return res
end

function M.terminate(pid) 
    local p = M.open(pid, 1); 
    if p then 
        local r, err = p:terminate(); p:close(); return r, err 
    end
    return false, "Process not found" 
end

function M.terminate_gracefully(pid, timeout)
    local h = kernel32.OpenProcess(0x100001, false, pid)
    if not h and kernel32.GetLastError() == 5 then
        token.enable_privilege("SeDebugPrivilege")
        h = kernel32.OpenProcess(0x100001, false, pid)
    end
    if not h then return false, util.last_error() end

    local ptr = ffi.new("DWORD[1]")
    jit.off()
    local cb = ffi.cast("WNDENUMPROC", function(w, l)
        local ok = pcall(function()
            user32.GetWindowThreadProcessId(w, ptr)
            if ptr[0] == pid then user32.PostMessageW(w, 0x0010, 0, 0) end
        end)
        return 1
    end)
    user32.EnumWindows(cb, 0)
    cb:free()
    jit.on()

    if kernel32.WaitForSingleObject(h, timeout or 3000) == 258 then
        kernel32.TerminateProcess(h, 0)
    end
    kernel32.CloseHandle(h)
    return true
end

local function terminate_tree_optimized(root_pid)
    local snapshot = M.list()
    local child_map = {}
    for _, p in ipairs(snapshot) do
        local ppid = p.parent_pid
        if not child_map[ppid] then child_map[ppid] = {} end
        table.insert(child_map[ppid], p.pid)
    end
    local to_kill = {}
    local function collect(pid)
        table.insert(to_kill, pid)
        local children = child_map[pid]
        if children then
            for _, child_pid in ipairs(children) do collect(child_pid) end
        end
    end
    collect(root_pid)
    token.enable_privilege("SeDebugPrivilege")
    for _, pid in ipairs(to_kill) do M.terminate(pid) end
    return true
end

function M.kill(pid, mode)
    if mode == "soft" then return M.terminate_gracefully(pid)
    elseif mode == "tree" then return terminate_tree_optimized(pid)
    else return M.terminate(pid) end
end

function M.wait(name_or_pid, timeout)
    local start = kernel32.GetTickCount64()
    timeout = timeout or -1
    while true do
        local pid = M.exists(name_or_pid)
        if pid ~= 0 then return pid end
        if timeout >= 0 and (kernel32.GetTickCount64() - start) > timeout then return nil end
        kernel32.Sleep(100)
    end
end

function M.wait_close(name_or_pid, timeout)
    local pid = M.exists(name_or_pid)
    if pid == 0 then return true end
    local h = kernel32.OpenProcess(0x100000, false, pid)
    if not h then return false end
    local res = kernel32.WaitForSingleObject(h, timeout or -1)
    kernel32.CloseHandle(h)
    return res == 0
end

return M