local lu = require('luaunit')
local win = require('win-utils')

TestNet = {}

function TestNet:test_Adapter()
    local list, err = win.net.adapter.list()
    lu.assertNotNil(list, "List adapters failed: " .. tostring(err))
    lu.assertTrue(#list > 0)
    
    for _, a in ipairs(list) do
        lu.assertIsString(a.name)
        lu.assertIsTable(a.ips)
        lu.assertIsTable(a.gateways)
        
        if #a.ips > 0 then
            print(string.format("  [INFO] Adapter: %s | IP: %s", a.name, a.ips[1]))
        end
    end
end

function TestNet:test_TCP_List()
    local conns, err = win.net.stat.list_tcp()
    lu.assertNotNil(conns, "List TCP failed: " .. tostring(err))
    lu.assertIsTable(conns)
    if #conns > 0 then
        lu.assertIsNumber(conns[1].pid)
        lu.assertIsString(conns[1].state)
    end
    
    local listeners = win.net.stat.get_tcp_listeners()
    lu.assertIsTable(listeners)
end

function TestNet:test_Stat_Netstat_And_Filter()
    if win.net.stat and win.net.stat.netstat then
        local tcp = win.net.stat.netstat()
        lu.assertIsTable(tcp)
        
        if tcp.filter then
            lu.assertIsFunction(tcp.filter)
            local filtered = tcp:filter(function(c) return c.state == "LISTEN" end)
            lu.assertIsTable(filtered)
        else
            print("  [WARN] netstat result missing 'filter' method (Lua-Ext missing?)")
        end
    end
end

function TestNet:test_ICMP()
    local ok, err = win.net.icmp.ping("127.0.0.1", 500)
    lu.assertTrue(ok, "Ping failed: " .. tostring(err))
end

function TestNet:test_DNS()
    local ok, err = win.net.dns.flush()
    lu.assertTrue(ok, "Flush DNS failed: " .. tostring(err))
end