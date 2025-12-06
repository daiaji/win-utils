local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local bit = require 'bit'
local table_new = require 'table.new'
local table_ext = require 'ext.table'
local util = require 'win-utils.core.util'

local M = {}
local STATES = {[1]="CLOSED",[2]="LISTEN",[3]="SYN_SENT",[4]="SYN_RCVD",[5]="ESTAB",[12]="DEL"}

local function ip_str(v) 
    return (bit.band(v,0xFF)) .. "." .. (bit.band(bit.rshift(v,8),0xFF)) .. "." .. (bit.band(bit.rshift(v,16),0xFF)) .. "." .. (bit.band(bit.rshift(v,24),0xFF))
end
local function port(v) return bit.bor(bit.rshift(v,8), bit.lshift(bit.band(v,0xFF),8)) end

function M.list_tcp()
    local sz = ffi.new("DWORD[1]", 0)
    iphlp.GetExtendedTcpTable(nil, sz, 0, 2, 5, 0)
    
    local buf = ffi.new("uint8_t[?]", sz[0])
    if iphlp.GetExtendedTcpTable(buf, sz, 0, 2, 5, 0) ~= 0 then 
        return nil, util.last_error("GetExtendedTcpTable failed")
    end
    
    local t = ffi.cast("MIB_TCPTABLE_OWNER_PID*", buf)
    local num = tonumber(t.dwNumEntries)
    
    local r = table_new(num, 0)
    setmetatable(r, { __index = table_ext })
    
    for i=0, num-1 do
        local e = t.table[i]
        r[i+1] = {
            pid = tonumber(e.dwOwningPid), 
            state = STATES[tonumber(e.dwState)] or "UNK",
            local_ip = ip_str(e.dwLocalAddr), 
            local_port = port(e.dwLocalPort),
            remote_ip = ip_str(e.dwRemoteAddr), 
            remote_port = port(e.dwRemotePort)
        }
    end
    return r
end

function M.get_tcp_listeners()
    local l, err = M.list_tcp()
    if not l then return nil, err end
    return l:filter(function(e) return e.state == "LISTEN" end)
            :map(function(e) return { port=e.local_port, pid=e.pid } end)
end

function M.find_pid_by_port(p)
    local l = M.list_tcp()
    if not l then return nil end
    local _, res = l:findIf(function(e) return e.local_port == p end)
    return res and res.pid or nil
end

return M