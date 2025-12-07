local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'
local util = require 'win-utils.core.util'
local M = {}

-- [RESTORED] 返回 (success, rtt_ms)
function M.ping(addr, timeout)
    local h = iphlp.IcmpCreateFile()
    if h == ffi.cast("HANDLE", -1) then 
        return false, util.last_error("IcmpCreateFile failed") 
    end
    
    local rep_size = ffi.sizeof("ICMP_ECHO_REPLY") + 32
    local rep = ffi.new("uint8_t[?]", rep_size)
    
    local ip = ws2.inet_addr(addr)
    if ip == 0xFFFFFFFF then -- INADDR_NONE
        iphlp.IcmpCloseHandle(h)
        return false, "Invalid IP address"
    end
    
    local t = timeout or 1000
    local r = iphlp.IcmpSendEcho(h, ip, nil, 0, nil, rep, rep_size, t)
    
    local success = false
    local rtt = 0
    local err_msg = nil
    
    if r > 0 then
        local reply = ffi.cast("ICMP_ECHO_REPLY*", rep)
        if reply.Status == 0 then -- IP_SUCCESS
            success = true
            rtt = tonumber(reply.RoundTripTime)
        else
            err_msg = string.format("Ping Status: %d", reply.Status)
        end
    else
        err_msg = util.last_error("IcmpSendEcho failed")
    end
    
    iphlp.IcmpCloseHandle(h)
    
    if not success then return false, err_msg end
    return true, rtt
end

return M