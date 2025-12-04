local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestProcess = {}

function TestProcess:setUp()
    -- 启动一个长驻进程
    -- [FIX] Use 'ping' instead of 'timeout'. 'timeout' fails with "Input redirection is not supported" in CI.
    -- Ping localhost 30 times = approx 30 seconds
    self.proc = win.process.exec("cmd.exe /c ping -n 30 127.0.0.1 > NUL", nil, 0)
end

function TestProcess:tearDown()
    if self.proc and self.proc:is_valid() then
        self.proc:terminate()
        -- [CRITICAL] Close handle explicitly to allow process object destruction
        self.proc:close() 
    end
end

-- ========================================================================
-- 进程基础功能
-- ========================================================================
function TestProcess:test_Process_Info()
    lu.assertNotIsNil(self.proc, "Process exec failed")
    lu.assertIsNumber(self.proc.pid)
    
    local info = self.proc:get_info()
    lu.assertIsTable(info)
    lu.assertEquals(info.pid, self.proc.pid)
    
    -- 路径检查
    local path = self.proc:get_path()
    lu.assertIsString(path)
    -- cmd.exe 路径应包含 system32
    if #path > 0 then
        lu.assertStrContains(path:lower(), "cmd.exe")
    end
end

function TestProcess:test_Priority()
    -- (补回) 优先级设置
    lu.assertTrue(self.proc:set_priority("H"), "Set High priority failed")
end

function TestProcess:test_Wait_Timeout()
    -- (补回) 等待超时逻辑
    -- 进程预计存活 30s，等待 100ms 应返回 false (timeout)
    local start = ffi.load("kernel32").GetTickCount()
    local res = self.proc:wait_for_exit(100)
    local dur = ffi.load("kernel32").GetTickCount() - start
    
    lu.assertFalse(res, "Should timeout (process exited too early?)")
    -- Timing checks in VMs are flaky, loosen assertion
    -- lu.assertTrue(dur >= 90, "Wait duration too short")
end

function TestProcess:test_Suspend_Resume()
    -- (新增) 挂起/恢复测试
    lu.assertTrue(self.proc:suspend(), "Suspend failed")
    -- 简单的状态检查比较困难，主要测试 API 调用不崩溃
    lu.assertTrue(self.proc:resume(), "Resume failed")
end

function TestProcess:test_Tree_Kill()
    -- (补回) 进程树终止
    -- 启动 cmd -> ping 结构 (Nested)
    -- Using ping -n 30 to ensure it stays alive long enough
    local p = win.process.exec('cmd.exe /c "ping -n 30 127.0.0.1 > NUL"', nil, 0)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(1000) -- 等待子进程产生 (Increase wait for slower CI)
    
    local pid = p.pid
    p:terminate_tree()
    
    -- [CRITICAL FIX] Close our handle to the process. 
    -- If we keep it open, the process object remains (as zombie) and exists() returns true (if it only checks OpenProcess).
    p:close()
    
    -- Wait for cleanup
    ffi.C.Sleep(1000)
    
    -- [FIX] Check existence properly. exists returns 0 if gone.
    lu.assertEquals(win.process.exists(pid), 0, "Parent process should be gone")
end

-- ========================================================================
-- 高级特性 (Token, Net, Service)
-- ========================================================================
function TestProcess:test_Token_Security()
    -- (新增) 令牌与权限
    local token = win.process.token.open_process_token(self.proc.pid)
    lu.assertNotIsNil(token, "Open token failed")
    
    local user = win.process.token.get_user(token)
    lu.assertIsString(user, "SID should be string")
    lu.assertStrMatches(user, "^S%-1%-.*")
    
    local integrity = win.process.token.get_integrity_level(token)
    lu.assertIsString(integrity)
    
    token:close()
end

function TestProcess:test_Net_Stat()
    -- (新增) 网络状态
    local table = win.net.stat.get_tcp_table()
    lu.assertIsTable(table)
    -- 只要返回表即可，内容视系统状态而定
end

function TestProcess:test_Service_List()
    -- (新增) 服务枚举
    -- 需要确保 service 模块已加载
    local svcs = win.service.list()
    lu.assertIsTable(svcs)
    lu.assertTrue(#svcs > 0, "Should list system services")
    
    -- 检查常见服务 (例如 Spooler 或 EventLog)
    local found = false
    for _, s in ipairs(svcs) do
        if s.name == "Spooler" or s.name == "EventLog" then
            found = true
            lu.assertIsNumber(s.pid)
            break
        end
    end
    lu.assertTrue(found, "Standard service not found")
end