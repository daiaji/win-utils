local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local bit = require 'bit'
local M = {}

local STATES = {[1]="CLOSED",[2]="LISTEN",[3]="SYN_SENT",[4]="SYN_RCVD",[5]="ESTAB",[12]="DEL"}

local function ip_str(v) 
    return string.format("%d.%d.%d.%d", bit.band(v,0xFF), bit.band(bit.rshift(v,8),0xFF), bit.band(bit.rshift(v,16),0xFF), bit.band(bit.rshift(v,24),0xFF)) 
end

local function port(v) return bit.bor(bit.rshift(v,8), bit.lshift(bit.band(v,0xFF),8)) end

function M.netstat()
    local sz = ffi.new("DWORD[1]", 0)
    iphlp.GetExtendedTcpTable(nil, sz, 0, 2, 5, 0)
    local buf = ffi.new("uint8_t[?]", sz[0])
    if iphlp.GetExtendedTcpTable(buf, sz, 0, 2, 5, 0) ~= 0 then return {} end
    local t = ffi.cast("MIB_TCPTABLE_OWNER_PID*", buf)
    local r = {}
    for i=0, tonumber(t.dwNumEntries)-1 do
        local e = t.table[i]
        table.insert(r, {
            pid=tonumber(e.dwOwningPid), 
            state=STATES[tonumber(e.dwState)] or "UNK",
            local_ip=ip_str(e.dwLocalAddr), local_port=port(e.dwLocalPort),
            remote_ip=ip_str(e.dwRemoteAddr), remote_port=port(e.dwRemotePort)
        })
    end
    return r
end

function M.get_tcp_listeners()
    local r = {}
    for _, e in ipairs(M.netstat()) do
        if e.state == "LISTEN" then table.insert(r, { port=e.local_port, pid=e.pid }) end
    end
    return r
end

function M.find_pid_by_port(p)
    for _, e in ipairs(M.netstat()) do
        if e.local_port == p then return e.pid end
    end
    return nil
end

return M