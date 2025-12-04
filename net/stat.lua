local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local bit = require 'bit' -- LuaJIT BitOp
local table_new = require 'table.new' -- LuaJIT Extension
local table_ext = require 'ext.table' -- Lua-Ext
local M = {}

local STATES = {[1]="CLOSED",[2]="LISTEN",[3]="SYN_SENT",[4]="SYN_RCVD",[5]="ESTAB",[12]="DEL"}

-- [LuaJIT Optimization] 使用 bit 库手动拼接 IP，避免 string.format 的开销
local function ip_str(v) 
    return (bit.band(v,0xFF)) .. "." ..
           (bit.band(bit.rshift(v,8),0xFF)) .. "." ..
           (bit.band(bit.rshift(v,16),0xFF)) .. "." ..
           (bit.band(bit.rshift(v,24),0xFF))
end

local function port(v) 
    return bit.bor(bit.rshift(v,8), bit.lshift(bit.band(v,0xFF),8)) 
end

function M.netstat()
    local sz = ffi.new("DWORD[1]", 0)
    
    -- 第一次调用获取大小
    iphlp.GetExtendedTcpTable(nil, sz, 0, 2, 5, 0)
    
    local buf = ffi.new("uint8_t[?]", sz[0])
    if iphlp.GetExtendedTcpTable(buf, sz, 0, 2, 5, 0) ~= 0 then return {} end
    
    local t = ffi.cast("MIB_TCPTABLE_OWNER_PID*", buf)
    local num = tonumber(t.dwNumEntries)
    
    -- [LuaJIT] 预分配 table 大小 (Array部分=num, Hash部分=0)
    local r = table_new(num, 0)
    
    -- [Lua-Ext] 赋予扩展能力 (允许 :find, :filter, :map)
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

-- [Lua-Ext Feature] 使用 :filter 和 :map 的链式调用
function M.get_tcp_listeners()
    return M.netstat()
        :filter(function(e) return e.state == "LISTEN" end)
        :map(function(e) return { port=e.local_port, pid=e.pid } end)
end

-- [Lua-Ext Feature] 使用 :find 查找
function M.find_pid_by_port(p)
    local _, res = M.netstat():find(function(e) return e.local_port == p end)
    return res and res.pid or nil
end

return M