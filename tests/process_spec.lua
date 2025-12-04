local lu = require('luaunit')
local win = require('win-utils')

TestProcess = {}

function TestProcess:setUp()
    self.proc = win.process.exec("cmd.exe /c ping -n 10 127.0.0.1 > NUL", nil, 0)
end

function TestProcess:tearDown()
    if self.proc then self.proc:terminate(); self.proc:close() end
end

function TestProcess:test_Basic()
    if not self.proc then return end
    local info = self.proc:get_info()
    lu.assertIsTable(info)
    lu.assertEquals(info.pid, self.proc.pid)
end

function TestProcess:test_List()
    local list = win.process.list()
    lu.assertIsTable(list)
    
    if self.proc then
        -- [Lua-Ext Feature] 极简查找
        local _, found = list:find(function(p) return p.pid == self.proc.pid end)
        lu.assertNotNil(found, "Created process not found in list")
    end
end

function TestProcess:test_SuspendResume()
    if not self.proc then return end
    lu.assertIsBoolean(self.proc:suspend())
    lu.assertIsBoolean(self.proc:resume())
end

function TestProcess:test_Token()
    local t = win.process.token.open_current(8)
    if t then
        local user = win.process.token.get_user(t)
        if user then print("\n[INFO] User: " .. user) end
        t:close()
    end
end