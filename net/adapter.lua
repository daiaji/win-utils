local ffi = require 'ffi'
local bit = require 'bit'
local iphlpapi = require 'ffi.req' 'Windows.sdk.iphlpapi'
local util = require 'win-utils.util'

local M = {}

local function sockaddr_to_string(sockaddr_ptr)
    if sockaddr_ptr == nil then return nil end
    local family = ffi.cast("short*", sockaddr_ptr)[0]
    if family == 2 then -- AF_INET
        local sin = ffi.cast("uint8_t*", sockaddr_ptr)
        return string.format("%d.%d.%d.%d", sin[4], sin[5], sin[6], sin[7])
    end
    return nil
end

local function format_mac(ptr, len)
    if len == 0 then return "" end
    local t = {}
    for i = 0, len - 1 do table.insert(t, string.format("%02X", ptr[i])) end
    return table.concat(t, "-")
end

function M.list()
    local flags = bit.bor(iphlpapi.C.GAA_FLAG_INCLUDE_PREFIX, iphlpapi.C.GAA_FLAG_INCLUDE_GATEWAYS)
    local size = ffi.new("ULONG[1]", 15 * 1024)
    local buf = ffi.new("uint8_t[?]", size[0])
    
    local res = iphlpapi.GetAdaptersAddresses(2, flags, nil, ffi.cast("IP_ADAPTER_ADDRESSES*", buf), size)
    if res == 111 then
        buf = ffi.new("uint8_t[?]", size[0])
        res = iphlpapi.GetAdaptersAddresses(2, flags, nil, ffi.cast("IP_ADAPTER_ADDRESSES*", buf), size)
    end
    if res ~= 0 then return nil, "GetAdaptersAddresses failed: " .. res end
    
    local adapters = {}
    local curr = ffi.cast("IP_ADAPTER_ADDRESSES*", buf)
    while curr ~= nil do
        local adapter = {
            name = ffi.string(curr.AdapterName),
            description = util.from_wide(curr.Description),
            mac = format_mac(curr.PhysicalAddress, curr.PhysicalAddressLength),
            status = tonumber(curr.OperStatus), -- 1=Up
            type = tonumber(curr.IfType),
            ips = {}, gateways = {}
        }
        local uni = curr.FirstUnicastAddress
        while uni ~= nil do
            local ip = sockaddr_to_string(uni.Address.lpSockaddr)
            if ip then table.insert(adapter.ips, ip) end
            uni = uni.Next
        end
        table.insert(adapters, adapter)
        curr = curr.Next
    end
    return adapters
end

return M