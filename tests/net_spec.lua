local lu = require('luaunit')
local win = require('win-utils')

TestNet = {}

function TestNet:test_Adapter()
    local list = win.net.adapter.list()
    lu.assertIsTable(list)
    -- CI 环境肯定有网络适配器
    lu.assertTrue(#list > 0, "No network adapters found")
    
    -- [New] 验证 IP 地址字段是否存在 (Restored Feature)
    local has_ip = false
    for _, adapter in ipairs(list) do
        lu.assertIsTable(adapter.ips)
        lu.assertIsTable(adapter.gateways)
        
        if #adapter.ips > 0 then
            has_ip = true
            print(string.format("  [INFO] Adapter: %s | IP: %s", adapter.name, adapter.ips[1]))
        end
    end
    
    if not has_ip then
        print("  [WARN] No adapters have IP addresses (Expected in some CI envs)")
    end
end

function TestNet:test_Stat()
    local tcp = win.net.stat.netstat()
    lu.assertIsTable(tcp)
    -- 验证 Lua-Ext 扩展方法是否可用
    lu.assertIsFunction(tcp.filter, "Lua-Ext table methods missing on netstat result")
end

function TestNet:test_ICMP()
    -- GitHub Actions 通常封锁 ICMP (Ping)
    local ok = win.net.icmp.ping("127.0.0.1")
    lu.assertIsBoolean(ok)
    
    if not ok then
        print("\n  [INFO] ICMP Ping failed (Firewall/CI Block)")
    end
end