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
    
    if kernel32.CreatePipe(hRead, hWrite, sa, 0) == 0 then
        return nil, util.last_error("CreatePipe failed")
    end
    
    -- [关键] 确保管道的读取端不被子进程继承
    -- 否则如果父进程不关闭读取端，子进程可能会持有它导致死锁或逻辑混乱
    if kernel32.SetHandleInformation(hRead[0], HANDLE_FLAG_INHERIT, 0) == 0 then
        kernel32.CloseHandle(hRead[0])
        kernel32.CloseHandle(hWrite[0])
        return nil, util.last_error("SetHandleInformation failed")
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
        si.hStdError = hWrite[0]
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
    
    -- 防止 GC 提前回收字符串缓冲区
    local _ = {wcmd, wdir}
    
    if res == 0 then
        kernel32.CloseHandle(hRead[0])
        return nil, util.last_error("CreateProcess failed")
    end
    
    -- 4. 读取输出循环
    local chunk_size = 4096
    local buf = ffi.new("uint8_t[?]", chunk_size)
    local read_bytes = ffi.new("DWORD[1]")
    local output_parts = {}
    local read_ok = true
    
    while true do
        -- 阻塞读取，直到缓冲区有数据或管道被所有写入者关闭
        local ok = kernel32.ReadFile(hRead[0], buf, chunk_size, read_bytes, nil)
        
        if ok == 0 then
            local err = kernel32.GetLastError()
            if err == 109 then -- ERROR_BROKEN_PIPE (正常结束)
                break 
            end
            -- 其他错误忽略，尝试继续或退出
            break
        end
        
        if read_bytes[0] == 0 then break end -- EOF
        
        table.insert(output_parts, ffi.string(buf, read_bytes[0]))
    end
    
    kernel32.CloseHandle(hRead[0])
    
    -- 5. 等待进程退出并获取退出码
    kernel32.WaitForSingleObject(pi.hProcess, opts.timeout or -1)
    
    local exit_code = ffi.new("DWORD[1]")
    kernel32.GetExitCodeProcess(pi.hProcess, exit_code)
    
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(pi.hProcess)
    
    -- 6. 返回结果
    return table.concat(output_parts), tonumber(exit_code[0])
end

return M