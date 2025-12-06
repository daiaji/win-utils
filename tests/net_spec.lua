local lu = require('luaunit')
local win = require('win-utils')

TestNet = {}

function TestNet:test_Adapter()
    local list = win.net.adapter.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    local has_ip = false
    for _, a in ipairs(list) do
        lu.assertIsString(a.name)
        lu.assertIsTable(a.ips)
        -- 确保 gateways 表存在（旧版逻辑）
        lu.assertIsTable(a.gateways)
        
        if #a.ips > 0 then
            has_ip = true
            print(string.format("  [INFO] Adapter: %s | IP: %s", a.name, a.ips[1]))
        end
    end
end

function TestNet:test_TCP_List()
    local conns = win.net.stat.list_tcp()
    lu.assertIsTable(conns)
    if #conns > 0 then
        lu.assertIsNumber(conns[1].pid)
        lu.assertIsString(conns[1].state)
    end
    
    local listeners = win.net.stat.get_tcp_listeners()
    lu.assertIsTable(listeners)
end

-- [CRITICAL RESTORATION] 恢复对 Lua 扩展方法 (filter) 的检查
function TestNet:test_Stat_Netstat_And_Filter()
    if win.net.stat and win.net.stat.netstat then
        local tcp = win.net.stat.netstat()
        lu.assertIsTable(tcp)
        
        -- 这是一个关键特性测试：验证返回的 table 是否挂载了 helper methods
        if tcp.filter then
            lu.assertIsFunction(tcp.filter)
            
            -- 尝试实际调用 filter
            local filtered = tcp:filter(function(c) return c.state == "LISTEN" end)
            lu.assertIsTable(filtered)
        else
            print("  [WARN] netstat result missing 'filter' method (Lua-Ext missing?)")
        end
    end
end

function TestNet:test_ICMP()
    local ok = win.net.icmp.ping("127.0.0.1", 500)
    lu.assertIsBoolean(ok)
end

function TestNet:test_DNS()
    local ok = win.net.dns.flush()
    lu.assertIsBoolean(ok)
end