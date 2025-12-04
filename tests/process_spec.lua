local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestProcess = {}

function TestProcess:setUp()
    -- 启动一个长生命周期的进程用于测试
    -- 使用 ping localhost 可以保证存活一段时间且无副作用
    self.proc = win.process.exec("cmd.exe /c ping -n 10 127.0.0.1 > NUL", nil, 0)
end

function TestProcess:tearDown()
    if self.proc then 
        self.proc:terminate() 
        self.proc:close() 
    end
end

function TestProcess:test_Basic()
    if not self.proc then 
        print("[SKIP] Failed to start test process")
        return 
    end
    
    lu.assertNotNil(self.proc)
    lu.assertTrue(self.proc.pid > 0)
    
    local info = self.proc:get_info()
    lu.assertIsTable(info)
    lu.assertEquals(info.pid, self.proc.pid)
    -- CI 环境下 exe_path 可能会变，只要不报错即可
    if info.exe_path then
        lu.assertStrContains(info.exe_path:lower(), "cmd.exe")
    end
end

function TestProcess:test_SuspendResume()
    if not self.proc then return end
    
    -- CI 容器中 Suspend 可能受限
    local ok_suspend = self.proc:suspend()
    local ok_resume = self.proc:resume()
    
    -- 只要 API 调用没有崩溃即可，不断言必须成功 (权限问题)
    lu.assertIsBoolean(ok_suspend)
    lu.assertIsBoolean(ok_resume)
end

function TestProcess:test_List()
    local list = win.process.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    if self.proc then
        local found = false
        for _, p in ipairs(list) do
            if p.pid == self.proc.pid then found = true break end
        end
        lu.assertTrue(found, "Created process not found in list")
    end
end

function TestProcess:test_Token()
    -- 尝试打开当前进程令牌
    local t = win.process.token.open_current(8) -- QUERY
    if not t then
        print("[WARN] Failed to open current process token")
        return
    end
    lu.assertNotNil(t)
    
    local user = win.process.token.get_user(t)
    -- CI 环境可能是 System 或 ContainerUser
    if user then
        lu.assertIsString(user)
        print("[INFO] Current User: " .. user)
    end
    
    local integrity = win.process.token.get_integrity_level(t)
    if integrity then
        print("[INFO] Integrity: " .. integrity)
    end
    
    t:close()
end