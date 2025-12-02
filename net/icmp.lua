local ffi = require 'ffi'
local iphlpapi = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'
local bit = require 'bit'

local M = {}

function M.ping(ip, timeout)
    timeout = timeout or 1000
    local hIcmp = iphlpapi.IcmpCreateFile()
    if hIcmp == ffi.cast("HANDLE", -1) then return false, "IcmpCreateFile failed" end
    
    local dest_addr = ws2.inet_addr(ip)
    if dest_addr == 0xFFFFFFFF then
        iphlpapi.IcmpCloseHandle(hIcmp)
        return false, "Invalid IP"
    end
    
    local send_data = "PingPayload"
    local reply_size = ffi.sizeof("ICMP_ECHO_REPLY") + #send_data + 8
    local reply_buf = ffi.new("uint8_t[?]", reply_size)
    
    local ret = iphlpapi.IcmpSendEcho(hIcmp, dest_addr, ffi.cast("void*", send_data), #send_data, nil, reply_buf, reply_size, timeout)
    local success = false
    local rtt = 0
    if ret > 0 then
        local reply = ffi.cast("ICMP_ECHO_REPLY*", reply_buf)
        if reply.Status == 0 then success = true; rtt = tonumber(reply.RoundTripTime) end
    end
    iphlpapi.IcmpCloseHandle(hIcmp)
    return success, rtt
end

return M