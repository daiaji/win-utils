local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'
local M = {}
function M.ping(addr)
    local h = iphlp.IcmpCreateFile()
    local rep = ffi.new("uint8_t[1024]")
    local ip = ws2.inet_addr(addr)
    local r = iphlp.IcmpSendEcho(h, ip, nil, 0, nil, rep, 1024, 1000)
    iphlp.IcmpCloseHandle(h)
    return r > 0
end
return M