local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local C = ffi.C
local INVALID_HANDLE = ffi.cast("HANDLE", -1)

local M = {}

-- 常量定义
local STARTF_USESTDHANDLES = 0x00000100
local STARTF_USESHOWWINDOW = 0x00000001
local HANDLE_FLAG_INHERIT  = 0x00000001
local WAIT_OBJECT_0        = 0
local WAIT_TIMEOUT         = 258
local ERROR_BROKEN_PIPE    = 109
local STILL_ACTIVE         = 259

-- [API] 执行命令并捕获标准输出
-- @param cmd: 命令行字符串
-- @param opts: 选项表
--    opts.work_dir: 工作目录 (可选)
--    opts.show: 显示模式 (默认 0 = SW_HIDE)
--    opts.include_stderr: 是否合并错误输出 (默认 true)
--    opts.timeout: 等待超时毫秒 (默认 -1 无限等待)
-- @return: output_string, exit_code (或 nil, err_msg)
function M.run(cmd, opts)
    opts = opts or {}
    
    -- 1. 创建匿名管道
    -- 安全属性：bInheritHandle = TRUE，以便子进程继承写入句柄
    local sa = ffi.new("SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof(sa)
    sa.bInheritHandle = 1 
    
    local hRead = ffi.new("HANDLE[1]")
    local hWrite = ffi.new("HANDLE[1]")
    local hErrRead = ffi.new("HANDLE[1]")
    local hErrWrite = ffi.new("HANDLE[1]")
    
    if kernel32.CreatePipe(hRead, hWrite, sa, 0) == 0 then
        return nil, util.last_error("CreatePipe failed")
    end

    if opts.separate_stderr then
        if kernel32.CreatePipe(hErrRead, hErrWrite, sa, 0) == 0 then
            kernel32.CloseHandle(hRead[0])
            kernel32.CloseHandle(hWrite[0])
            return nil, util.last_error("CreatePipe(stderr) failed")
        end
    end
    
    -- [关键] 确保管道的读取端不被子进程继承
    -- 否则如果父进程不关闭读取端，子进程可能会持有它导致死锁或逻辑混乱
    if kernel32.SetHandleInformation(hRead[0], HANDLE_FLAG_INHERIT, 0) == 0 then
        kernel32.CloseHandle(hRead[0])
        kernel32.CloseHandle(hWrite[0])
        if opts.separate_stderr then
            kernel32.CloseHandle(hErrRead[0])
            kernel32.CloseHandle(hErrWrite[0])
        end
        return nil, util.last_error("SetHandleInformation failed")
    end

    if opts.separate_stderr and kernel32.SetHandleInformation(hErrRead[0], HANDLE_FLAG_INHERIT, 0) == 0 then
        kernel32.CloseHandle(hRead[0])
        kernel32.CloseHandle(hWrite[0])
        kernel32.CloseHandle(hErrRead[0])
        kernel32.CloseHandle(hErrWrite[0])
        return nil, util.last_error("SetHandleInformation(stderr) failed")
    end
    
    -- 2. 配置启动信息
    local si = ffi.new("STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    si.dwFlags = bit.bor(STARTF_USESTDHANDLES, STARTF_USESHOWWINDOW)
    si.wShowWindow = opts.show or 0 -- 默认隐藏
    
    -- 重定向 stdout 到管道写入端
    si.hStdOutput = hWrite[0]
    
    -- 根据配置决定是否重定向 stderr
    if opts.include_stderr ~= false then
        si.hStdError = opts.separate_stderr and hErrWrite[0] or hWrite[0]
    else
        -- 获取当前的 StdError 或设为 NULL
        -- 这里设为 NULL 避免干扰
        si.hStdError = nil
    end
    
    -- stdin 设为 nil (不提供输入)
    si.hStdInput = nil 
    
    local pi = ffi.new("PROCESS_INFORMATION")
    local wcmd = util.to_wide(cmd)
    local wdir = opts.work_dir and util.to_wide(opts.work_dir) or nil
    
    -- 3. 创建子进程
    -- bInheritHandles = TRUE (1) 必须为真
    local res = kernel32.CreateProcessW(
        nil, 
        wcmd, 
        nil, nil, 
        1, -- bInheritHandles
        0, -- CreationFlags
        nil, 
        wdir, 
        si, 
        pi
    )
    
    -- [关键] 无论成功失败，父进程必须关闭它持有的管道写入句柄
    -- 否则 ReadFile 永远无法检测到管道关闭（EOF）
    kernel32.CloseHandle(hWrite[0])
    if opts.separate_stderr then kernel32.CloseHandle(hErrWrite[0]) end
    
    -- 防止 GC 提前回收字符串缓冲区
    local _ = {wcmd, wdir}
    
    if res == 0 then
        kernel32.CloseHandle(hRead[0])
        if opts.separate_stderr then kernel32.CloseHandle(hErrRead[0]) end
        return nil, util.last_error("CreateProcess failed")
    end
    
    -- 4. 读取输出循环。先 Peek 再 Read，避免静默长任务卡住 timeout。
    local chunk_size = 4096
    local buf = ffi.new("uint8_t[?]", chunk_size)
    local read_bytes = ffi.new("DWORD[1]")
    local avail_bytes = ffi.new("DWORD[1]")
    local output_parts = {}
    local err_parts = {}
    local timed_out = false
    local exit_code = ffi.new("DWORD[1]", STILL_ACTIVE)
    local timeout = opts.timeout or -1
    local start_tick = kernel32.GetTickCount64()

    local function read_available(handle, parts)
        avail_bytes[0] = 0
        local peek_ok = C.PeekNamedPipe(handle, nil, 0, nil, avail_bytes, nil)
        if peek_ok == 0 then
            if kernel32.GetLastError() == ERROR_BROKEN_PIPE then return 0, true end
            return 0, false
        end
        local available = tonumber(avail_bytes[0])
        if available <= 0 then return 0, false end

        local to_read = math.min(available, chunk_size)
        local ok = kernel32.ReadFile(handle, buf, to_read, read_bytes, nil)
        if ok == 0 then
            if kernel32.GetLastError() == ERROR_BROKEN_PIPE then return 0, true end
            return 0, false
        end
        if read_bytes[0] > 0 then
            table.insert(parts, ffi.string(buf, read_bytes[0]))
        end
        return tonumber(read_bytes[0]), false
    end
    
    while true do
        local stdout_read, stdout_closed = read_available(hRead[0], output_parts)
        local stderr_read, stderr_closed = 0, not opts.separate_stderr

        if opts.separate_stderr then
            stderr_read, stderr_closed = read_available(hErrRead[0], err_parts)
        end

        local wait_res = kernel32.WaitForSingleObject(pi.hProcess, 0)
        if wait_res == WAIT_OBJECT_0 then
            if stdout_read == 0 and stderr_read == 0 then break end
        end

        if timeout >= 0 and (kernel32.GetTickCount64() - start_tick) >= timeout then
            timed_out = true
            if opts.kill_tree_on_timeout then
                local process = require 'win-utils.process.init'
                process.kill(tonumber(pi.dwProcessId), "tree")
            elseif opts.kill_on_timeout ~= false then
                kernel32.TerminateProcess(pi.hProcess, opts.timeout_exit_code or 1)
            end
            break
        end

        if stdout_closed and stderr_closed then break end
        if wait_res == WAIT_TIMEOUT and stdout_read == 0 and stderr_read == 0 then kernel32.Sleep(10) end
    end
    
    kernel32.CloseHandle(hRead[0])
    if opts.separate_stderr then kernel32.CloseHandle(hErrRead[0]) end
    
    -- 5. 等待进程退出并获取退出码
    if timed_out then kernel32.WaitForSingleObject(pi.hProcess, 1000)
    else kernel32.WaitForSingleObject(pi.hProcess, -1) end
    kernel32.GetExitCodeProcess(pi.hProcess, exit_code)
    
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(pi.hProcess)
    
    -- 6. 返回结果
    if timed_out then return table.concat(output_parts), tonumber(exit_code[0]), "timeout", table.concat(err_parts) end
    return table.concat(output_parts), tonumber(exit_code[0]), nil, table.concat(err_parts)
end

return M
