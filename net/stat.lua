local ffi = require 'ffi'
local bit = require 'bit'
local iphlpapi = require 'ffi.req' 'Windows.sdk.iphlpapi'

local M = {}
local TCP_STATE = { [1]="CLOSED",[2]="LISTEN",[3]="SYN_SENT",[4]="SYN_RCVD",[5]="ESTABLISHED",[6]="FIN_WAIT1",[7]="FIN_WAIT2",[8]="CLOSE_WAIT",[9]="CLOSING",[10]="LAST_ACK",[11]="TIME_WAIT",[12]="DELETE_TCB"}

local function parse_ip_port(addr, port)
    local port_val = bit.bor(bit.rshift(bit.band(port, 0xFF00), 8), bit.lshift(bit.band(port, 0x00FF), 8))
    local a = bit.band(addr, 0xFF)
    local b = bit.band(bit.rshift(addr, 8), 0xFF)
    local c = bit.band(bit.rshift(addr, 16), 0xFF)
    local d = bit.band(bit.rshift(addr, 24), 0xFF)
    return string.format("%d.%d.%d.%d", a, b, c, d), port_val
end

function M.list()
    local size = ffi.new("DWORD[1]", 0)
    iphlpapi.GetExtendedTcpTable(nil, size, 0, 2, 5, 0)
    local buf = ffi.new("uint8_t[?]", size[0])
    if iphlpapi.GetExtendedTcpTable(buf, size, 0, 2, 5, 0) ~= 0 then return {} end
    
    local table = ffi.cast("MIB_TCPTABLE_OWNER_PID*", buf)
    local results = {}
    for i = 0, tonumber(table.dwNumEntries) - 1 do
        local row = table.table[i]
        local l_ip, l_port = parse_ip_port(row.dwLocalAddr, row.dwLocalPort)
        local r_ip, r_port = parse_ip_port(row.dwRemoteAddr, row.dwRemotePort)
        table.insert(results, { proto="TCP", local_ip=l_ip, local_port=l_port, remote_ip=r_ip, remote_port=r_port, state=TCP_STATE[tonumber(row.dwState)] or "UNKNOWN", pid=tonumber(row.dwOwningPid) })
    end
    return results
end

return M