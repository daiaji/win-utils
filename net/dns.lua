local ffi = require 'ffi'
local dnsapi = require 'ffi.req' 'Windows.sdk.dnsapi'

local M = {}
function M.flush_cache() 
    return dnsapi.DnsFlushResolverCache() ~= 0 
end
return M