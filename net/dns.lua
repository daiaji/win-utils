local ffi = require 'ffi'
local dns = require 'ffi.req' 'Windows.sdk.dnsapi'
local util = require 'win-utils.core.util'
local M = {}

function M.flush() 
    local res = dns.DnsFlushResolverCache()
    if res == 0 then return false, util.last_error("DnsFlushResolverCache failed") end
    return true
end

return M