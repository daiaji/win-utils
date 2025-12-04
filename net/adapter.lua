local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local util = require 'win-utils.core.util'
local M = {}
function M.list()
    local sz = ffi.new("ULONG[1]", 15000)
    local buf = ffi.new("uint8_t[?]", sz[0])
    if iphlp.GetAdaptersAddresses(0, 0, nil, ffi.cast("void*", buf), sz) ~= 0 then return {} end
    local curr = ffi.cast("IP_ADAPTER_ADDRESSES*", buf)
    local r = {}
    while curr ~= nil do
        table.insert(r, {
            name=util.from_wide(curr.FriendlyName), 
            desc=util.from_wide(curr.Description),
            status = (tonumber(curr.OperStatus) == 1) and "Up" or "Down"
        })
        curr = curr.Next
    end
    return r
end
return M