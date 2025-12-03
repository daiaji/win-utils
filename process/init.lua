local ffi = require 'ffi'
local bit = require 'bit'

print("[PROCESS] Loading deps...")
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local psapi = require 'ffi.req' 'Windows.sdk.psapi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local class = require 'win-utils.deps'.class

local C = ffi.C
local INVALID_HANDLE = ffi.cast("HANDLE", -1)

local M = {}

-- 导出子模块
print("[PROCESS] Loading submodule: token")
M.token  = require 'win-utils.process.token'
print("[PROCESS] Loading submodule: memory")
M.memory = require 'win-utils.process.memory'
print("[PROCESS] Loading submodule: handle")
M.handle = require 'win-utils.process.handle'
print("[PROCESS] Loading submodule: job")
M.job    = require 'win-utils.process.job'
print("[PROCESS] Loading submodule: module")
M.module = require 'win-utils.process.module'

M.constants = {
    SW_HIDE=0, SW_SHOWNORMAL=1, SW_SHOW=5, 
    PROCESS_ALL_ACCESS=0x1F0FFF, PROCESS_TERMINATE=1, PROCESS_QUERY_INFORMATION=0x400, 
    SYNCHRONIZE=0x100000, PROCESS_SUSPEND_RESUME=0x0800
}

-- [Helper] 获取进程路径
local function get_process_path(pid, handle)
    local hProc = handle or kernel32.OpenProcess(0x1000, false, pid) -- QUERY_LIMITED
    if not hProc or hProc == INVALID_HANDLE then return "" end
    
    local buf = ffi.new("wchar_t[1024]")
    local size = ffi.new("DWORD[1]", 1024)
    local res = 0
    
    -- 优先尝试 QueryFullProcessImageName (WinVista+)
    if kernel32.QueryFullProcessImageNameW(hProc, 0, buf, size) ~= 0 then 
        res = 1
    -- 回退到 GetModuleFileNameEx (PSAPI)
    elseif psapi.GetModuleFileNameExW(hProc, nil, buf, 1024) > 0 then 
        res = 1 
    end
    
    if not handle then kernel32.CloseHandle(hProc) end
    return res ~= 0 and util.from_wide(buf) or ""
end

-- [Helper] 获取命令行
local function get_process_command_line(pid)
    local hProc = kernel32.OpenProcess(0x410, false, pid) -- QUERY_INFO | VM_READ
    if not hProc or hProc == INVALID_HANDLE then return "" end
    
    local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
    if ntdll.NtQueryInformationProcess(hProc, 0, pbi, ffi.sizeof(pbi), nil) < 0 or pbi.PebBaseAddress == nil then 
        kernel32.CloseHandle(hProc); return "" 
    end
    
    local peb = ffi.new("PEB")
    if kernel32.ReadProcessMemory(hProc, pbi.PebBaseAddress, peb, ffi.sizeof(peb), nil) == 0 then 
        kernel32.CloseHandle(hProc); return "" 
    end
    
    local params = ffi.new("RTL_USER_PROCESS_PARAMETERS")
    if kernel32.ReadProcessMemory(hProc, peb.ProcessParameters, params, ffi.sizeof(params), nil) == 0 then 
        kernel32.CloseHandle(hProc); return "" 
    end
    
    local len = params.CommandLine.Length
    local res = ""
    if len > 0 then
        local buf = ffi.new("uint8_t[?]", len + 2)
        if kernel32.ReadProcessMemory(hProc, params.CommandLine.Buffer, buf, len, nil) ~= 0 then
            res = util.from_wide(ffi.cast("wchar_t*", buf), len / 2)
        end
    end
    kernel32.CloseHandle(hProc)
    return res
end

-- [Class] Process 对象
local Process = class()

function Process:init(pid, handle) 
    self.pid = pid
    if handle then self.obj = Handle.new(handle) end 
end

function Process:handle() return self.obj and self.obj:get() end
function Process:is_valid() return self.obj and self.obj:is_valid() end
function Process:close() return self.obj and self.obj:close() or false end

function Process:terminate(e) 
    if self:is_valid() then kernel32.TerminateProcess(self:handle(), e or 0) end 
    return M.terminate_by_pid(self.pid, e) 
end

function Process:wait_for_exit(t) 
    if not self:is_valid() then return true end 
    return kernel32.WaitForSingleObject(self:handle(), t or -1) == 0 
end

function Process:suspend() 
    if self:is_valid() then return ntdll.NtSuspendProcess(self:handle()) >= 0 end 
    return M.suspend(self.pid) 
end

function Process:resume() 
    if self:is_valid() then return ntdll.NtResumeProcess(self:handle()) >= 0 end 
    return M.resume(self.pid) 
end

function Process:get_path() return get_process_path(self.pid, self:handle()) end
function Process:get_command_line() return get_process_command_line(self.pid) end

function Process:set_priority(p)
    local map = { L=0x40, B=0x4000, N=0x20, A=0x8000, H=0x80, R=0x100 }
    local val = map[p and p:upper()]
    if not val then return false, "Invalid priority" end
    
    local h = self:handle()
    local close = false
    if not h then
        h = kernel32.OpenProcess(0x200, false, self.pid) -- SET_INFO
        if not h then return false, util.format_error() end
        close = true
    end
    
    local res = kernel32.SetPriorityClass(h, val) ~= 0
    if close then kernel32.CloseHandle(h) end
    return res
end

function Process:terminate_tree()
    M.enable_privilege()
    local function kill_kids(pid) 
        for p in M.each() do 
            if p.parent_pid == pid and p.pid ~= pid then 
                kill_kids(p.pid)
                M.terminate_by_pid(p.pid) 
            end 
        end 
    end
    kill_kids(self.pid)
    return self:terminate()
end

function Process:get_info()
    if self.pid == 0 then return nil end
    local out = { pid = self.pid }
    local hProc = self:handle() or kernel32.OpenProcess(0x410, false, self.pid)
    if not hProc or hProc == INVALID_HANDLE then return nil end
    
    local sess = ffi.new("DWORD[1]")
    if kernel32.ProcessIdToSessionId(self.pid, sess) ~= 0 then out.session_id = sess[0] end
    
    local pbi = ffi.new("PROCESS_BASIC_INFORMATION")
    if ntdll.NtQueryInformationProcess(hProc, 0, pbi, ffi.sizeof(pbi), nil) == 0 then 
        out.parent_pid = tonumber(pbi.InheritedFromUniqueProcessId) 
    end
    
    local pmc = ffi.new("PROCESS_MEMORY_COUNTERS_EX"); pmc.cb = ffi.sizeof(pmc)
    if psapi.GetProcessMemoryInfo(hProc, pmc, ffi.sizeof(pmc)) ~= 0 then 
        out.memory_usage_bytes = tonumber(pmc.WorkingSetSize) 
    end
    
    out.exe_path = get_process_path(self.pid, hProc)
    out.command_line = get_process_command_line(self.pid)
    
    if not self:handle() then kernel32.CloseHandle(hProc) end
    return out
end

-- [Module API]

-- 迭代器模式：低内存开销遍历进程
function M.each()
    local hSnap = kernel32.CreateToolhelp32Snapshot(2, 0)
    if hSnap == INVALID_HANDLE then return function() end end
    local pe = ffi.new("PROCESSENTRY32W"); pe.dwSize = ffi.sizeof(pe)
    local first = true
    return function()
        local res = first and kernel32.Process32FirstW(hSnap, pe) or kernel32.Process32NextW(hSnap, pe)
        first = false
        if res == 0 then kernel32.CloseHandle(hSnap); return nil end
        return { 
            pid = tonumber(pe.th32ProcessID), 
            name = util.from_wide(pe.szExeFile), 
            parent_pid = tonumber(pe.th32ParentProcessID), 
            thread_count = tonumber(pe.cntThreads) 
        }
    end
end

function M.list() local t = {}; for p in M.each() do table.insert(t, p) end return t end

local function find_pid_by_name(n) 
    local l = n:lower()
    for p in M.each() do if p.name:lower() == l then return p.pid end end 
    return 0 
end

function M.find_all(n) 
    local t={}; local l=n:lower()
    for p in M.each() do if p.name:lower()==l then table.insert(t,p.pid) end end 
    return t 
end

function M.exists(n) 
    if type(n)=="number" then 
        local h=kernel32.OpenProcess(0x1000,false,n)
        if h and h~=INVALID_HANDLE then kernel32.CloseHandle(h); return n end 
        return 0 
    else 
        return find_pid_by_name(n) 
    end 
end

function M.exec(cmd, wd, show, dt)
    local si = ffi.new("STARTUPINFOW"); si.cb = ffi.sizeof(si); si.dwFlags = 1; si.wShowWindow = show or 5
    if dt then si.lpDesktop = util.to_wide(dt) end
    local pi = ffi.new("PROCESS_INFORMATION")
    local buf = ffi.new("wchar_t[?]", #cmd+1)
    ffi.copy(buf, util.to_wide(cmd), (#cmd+1)*2)
    
    if kernel32.CreateProcessW(nil, buf, nil, nil, false, 0, nil, wd and util.to_wide(wd), si, pi) == 0 then 
        return nil, util.format_error() 
    end
    kernel32.CloseHandle(pi.hThread)
    return Process(tonumber(pi.dwProcessId), pi.hProcess)
end

function M.open_by_pid(pid, acc) 
    local h = kernel32.OpenProcess(acc or 0x1F0FFF, false, pid or 0)
    return (h and h~=INVALID_HANDLE) and Process(pid, h) or nil, util.format_error() 
end

function M.open_by_name(n, acc) 
    local pid = find_pid_by_name(n)
    return pid>0 and M.open_by_pid(pid, acc) or nil, "Process not found" 
end

function M.current() return M.open_by_pid(kernel32.GetCurrentProcessId()) end

function M.terminate_by_pid(pid, e) 
    local h = kernel32.OpenProcess(1, false, pid)
    if not h or h==INVALID_HANDLE then return false end 
    local r = kernel32.TerminateProcess(h, e or 0)
    kernel32.CloseHandle(h)
    return r~=0 
end

function M.terminate_gracefully(pid, ms)
    require('jit').off() -- Callback safety
    ms = ms or 3000
    
    local h = kernel32.OpenProcess(0x100001, false, pid) -- SYNCHRONIZE | TERMINATE
    if not h or h==INVALID_HANDLE then require('jit').on(); return false end
    
    local pid_ptr = ffi.new("DWORD[1]")
    local cb = ffi.cast("WNDENUMPROC", function(w,l) 
        user32.GetWindowThreadProcessId(w, pid_ptr)
        if pid_ptr[0]==pid then user32.PostMessageW(w, 0x10, 0, 0) end -- WM_CLOSE
        return 1 
    end)
    
    user32.EnumWindows(cb, 0)
    cb:free()
    
    local res = kernel32.WaitForSingleObject(h, ms)
    if res==258 then kernel32.TerminateProcess(h, 0) end -- WAIT_TIMEOUT
    
    kernel32.CloseHandle(h)
    require('jit').on()
    return true
end

function M.suspend(pid) 
    local h = kernel32.OpenProcess(0x800, false, pid)
    if not h or h==INVALID_HANDLE then return false end 
    local r = ntdll.NtSuspendProcess(h)
    kernel32.CloseHandle(h)
    return r>=0 
end

function M.resume(pid) 
    local h = kernel32.OpenProcess(0x800, false, pid)
    if not h or h==INVALID_HANDLE then return false end 
    local r = ntdll.NtResumeProcess(h)
    kernel32.CloseHandle(h)
    return r>=0 
end

function M.wait(n, t) 
    t=t or -1
    local s=kernel32.GetTickCount64()
    while true do 
        local p=find_pid_by_name(n)
        if p>0 then return p end 
        if t>=0 and (kernel32.GetTickCount64()-s)>t then return nil end 
        kernel32.Sleep(100) 
    end 
end

function M.wait_close(np, t) 
    local p=tonumber(np) or find_pid_by_name(np)
    if p==0 then return true end 
    local h=kernel32.OpenProcess(0x100000, false, p) -- SYNCHRONIZE
    if not h or h==INVALID_HANDLE then return true end 
    local r=kernel32.WaitForSingleObject(h, t or -1)
    kernel32.CloseHandle(h)
    return r==0 
end

function M.enable_privilege() 
    -- [DEBUG] Trace privilege enabling
    print("[PROCESS] Enabling SeDebugPrivilege...")
    local ok, err = M.token.enable_privilege("SeDebugPrivilege") 
    print(string.format("[PROCESS] SeDebugPrivilege result: %s (Err: %s)", tostring(ok), tostring(err)))
end

-- [DEBUG] Temporarily protect execution to avoid hang on load
local ok, err = pcall(M.enable_privilege)
if not ok then print("[PROCESS] Failed to auto-enable privilege: " .. tostring(err)) end

print("[PROCESS] Module loaded.")
return M