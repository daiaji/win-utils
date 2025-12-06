local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'
local util = require 'win-utils.core.util'
local M = {}

function M.ping(addr, timeout)
    local h = iphlp.IcmpCreateFile()
    if h == ffi.cast("HANDLE", -1) then 
        return false, util.last_error("IcmpCreateFile failed") 
    end
    
    local rep = ffi.new("uint8_t[1024]")
    local ip = ws2.inet_addr(addr)
    if ip == 0xFFFFFFFF then -- INADDR_NONE
        iphlp.IcmpCloseHandle(h)
        return false, "Invalid IP address"
    end
    
    local t = timeout or 1000
    local r = iphlp.IcmpSendEcho(h, ip, nil, 0, nil, rep, 1024, t)
    
    local err
    if r == 0 then err = util.last_error("IcmpSendEcho failed") end
    
    iphlp.IcmpCloseHandle(h)
    
    if r == 0 then return false, err end
    return true
end

return M