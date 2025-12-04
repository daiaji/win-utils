local ffi = require 'ffi'
local dns = require 'ffi.req' 'Windows.sdk.dnsapi'
local M = {}
function M.flush() return dns.DnsFlushResolverCache() ~= 0 end
return M