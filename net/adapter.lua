local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local util = require 'win-utils.core.util'
local M = {}

local function sock_to_ip(ptr)
    if ptr == nil then return nil end
    local family = ffi.cast("short*", ptr)[0]
    if family == 2 then 
        local sin = ffi.cast("uint8_t*", ptr)
        return string.format("%d.%d.%d.%d", sin[4], sin[5], sin[6], sin[7])
    end
    return nil
end

function M.list()
    local flags = 0x90 -- INCLUDE_PREFIX | INCLUDE_GATEWAYS
    local sz = ffi.new("ULONG[1]", 15000)
    local buf = ffi.new("uint8_t[?]", sz[0])
    
    local res = iphlp.GetAdaptersAddresses(2, flags, nil, ffi.cast("void*", buf), sz)
    if res == 111 then -- ERROR_BUFFER_OVERFLOW
        buf = ffi.new("uint8_t[?]", sz[0])
        res = iphlp.GetAdaptersAddresses(2, flags, nil, ffi.cast("void*", buf), sz)
    end
    
    if res ~= 0 then return nil, util.last_error("GetAdaptersAddresses") end
    
    local curr = ffi.cast("IP_ADAPTER_ADDRESSES*", buf)
    local list = {}
    
    while curr ~= nil do
        local item = {
            name = util.from_wide(curr.FriendlyName), 
            desc = util.from_wide(curr.Description),
            status = (tonumber(curr.OperStatus) == 1) and "Up" or "Down",
            ips = {},
            gateways = {}
        }
        
        local ua = curr.FirstUnicastAddress
        while ua ~= nil do
            local ip = sock_to_ip(ua.Address.lpSockaddr)
            if ip then table.insert(item.ips, ip) end
            ua = ua.Next
        end
        
        local ga = curr.FirstGatewayAddress
        while ga ~= nil do
            local ip = sock_to_ip(ga.Address.lpSockaddr)
            if ip then table.insert(item.gateways, ip) end
            ga = ga.Next
        end
        
        table.insert(list, item)
        curr = curr.Next
    end
    return list
end

return M