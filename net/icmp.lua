local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'

local M = {}
function M.ping(ip, timeout)
    local h = iphlp.IcmpCreateFile()
    if h == ffi.cast("HANDLE", -1) then return false end
    local addr = ws2.inet_addr(ip)
    local rep = ffi.new("uint8_t[1024]")
    local ret = iphlp.IcmpSendEcho(h, addr, nil, 0, nil, rep, 1024, timeout or 1000)
    iphlp.IcmpCloseHandle(h)
    return ret > 0
end
return M