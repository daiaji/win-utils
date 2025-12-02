local ffi = require 'ffi'
local bit = require 'bit'
local iphlpapi = require 'ffi.req' 'Windows.sdk.iphlpapi'

local M = {}
local C = ffi.C

-- 获取所有 TCP 监听端口及其 PID
function M.get_tcp_listeners()
    local AF_INET = 2
    local TCP_TABLE_OWNER_PID_ALL = 5
    local size = ffi.new("DWORD[1]", 0)
    
    -- 第一次调用获取大小
    iphlpapi.GetExtendedTcpTable(nil, size, 0, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0)
    
    local buf = ffi.new("uint8_t[?]", size[0])
    if iphlpapi.GetExtendedTcpTable(buf, size, 0, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) ~= 0 then
        return nil
    end
    
    local table = ffi.cast("MIB_TCPTABLE_OWNER_PID*", buf)
    local results = {}
    
    for i = 0, tonumber(table.dwNumEntries) - 1 do
        local row = table.table[i]
        -- dwState: 2 = LISTEN
        if row.dwState == 2 then
            -- 端口是网络字节序 (Big Endian)，需要转换
            local port = bit.bor(
                bit.rshift(bit.band(row.dwLocalPort, 0xFF00), 8),
                bit.lshift(bit.band(row.dwLocalPort, 0x00FF), 8)
            )
            table.insert(results, {
                port = port,
                pid = tonumber(row.dwOwningPid)
            })
        end
    end
    return results
end

-- 查找占用指定端口的 PID
function M.find_pid_by_port(port)
    local list = M.get_tcp_listeners()
    if not list then return nil end
    for _, item in ipairs(list) do
        if item.port == port then return item.pid end
    end
    return nil
end

return M