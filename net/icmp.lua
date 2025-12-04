local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'

local M = {}
function M.ping(ip, timeout)
    local h = iphlp.IcmpCreateFile()
    if h == ffi.cast("HANDLE", -1) then return false end
    
    local addr = ws2.inet_addr(ip)
    -- Reply buffer must be large enough for ICMP_ECHO_REPLY + Data
    -- sizeof(ICMP_ECHO_REPLY) is ~28 bytes + options. 
    -- We'll allocate enough.
    local reply_size = ffi.sizeof("ICMP_ECHO_REPLY") + 32 + 8 
    local rep_buf = ffi.new("uint8_t[?]", reply_size)
    
    local ret = iphlp.IcmpSendEcho(h, addr, nil, 0, nil, rep_buf, reply_size, timeout or 1000)
    iphlp.IcmpCloseHandle(h)
    
    if ret > 0 then
        local reply = ffi.cast("ICMP_ECHO_REPLY*", rep_buf)
        if reply.Status == 0 then -- IP_SUCCESS
            -- [FIX] Return RTT as second value
            return true, tonumber(reply.RoundTripTime)
        end
    end
    return false
end
return M