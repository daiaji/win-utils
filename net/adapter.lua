local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local util = require 'win-utils.util'

local M = {}

function M.list()
    local len = ffi.new("ULONG[1]", 15000)
    local buf = ffi.new("uint8_t[?]", len[0])
    if iphlp.GetAdaptersAddresses(2, 0, nil, ffi.cast("IP_ADAPTER_ADDRESSES*", buf), len) ~= 0 then return {} end
    
    local res = {}
    local curr = ffi.cast("IP_ADAPTER_ADDRESSES*", buf)
    while curr ~= nil do
        table.insert(res, {
            name = util.from_wide(curr.FriendlyName),
            desc = util.from_wide(curr.Description),
            status = tonumber(curr.OperStatus) == 1 and "Up" or "Down"
        })
        curr = curr.Next
    end
    return res
end

return M