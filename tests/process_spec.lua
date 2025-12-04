local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestProcess = {}

function TestProcess:setUp()
    -- Start a long-running process
    self.proc = win.process.exec("cmd.exe /c ping -n 10 127.0.0.1 > NUL", nil, 0)
end

function TestProcess:tearDown()
    if self.proc then self.proc:terminate(); self.proc:close() end
end

function TestProcess:test_Basic()
    lu.assertNotNil(self.proc)
    lu.assertTrue(self.proc.pid > 0)
    
    local info = self.proc:get_info()
    lu.assertIsTable(info)
    lu.assertEquals(info.pid, self.proc.pid)
    lu.assertStrContains(info.exe_path:lower(), "cmd.exe")
end

function TestProcess:test_SuspendResume()
    lu.assertTrue(self.proc:suspend())
    -- In a real test we'd check CPU usage, but here just check API success
    lu.assertTrue(self.proc:resume())
end

function TestProcess:test_List()
    local list = win.process.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    local found = false
    for _, p in ipairs(list) do
        if p.pid == self.proc.pid then found = true break end
    end
    lu.assertTrue(found)
end

function TestProcess:test_Token()
    local t = win.process.token.open_current(8) -- QUERY
    lu.assertNotNil(t)
    local user = win.process.token.get_user(t)
    lu.assertIsString(user)
    t:close()
end