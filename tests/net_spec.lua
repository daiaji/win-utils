local lu = require('luaunit')
local win = require('win-utils')

TestNet = {}

function TestNet:test_Adapter()
    local list = win.net.adapter.list()
    lu.assertIsTable(list)
    if #list > 0 then
        lu.assertIsString(list[1].name)
    end
end

function TestNet:test_Stat()
    local tcp = win.net.stat.netstat()
    lu.assertIsTable(tcp)
    -- CI might not have connections, but table should exist
end

function TestNet:test_ICMP()
    -- Ping localhost
    local ok = win.net.icmp.ping("127.0.0.1")
    -- Some CI blocks ICMP, assert boolean type
    lu.assertIsBoolean(ok)
end