local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
local ws2 = require 'ffi.req' 'Windows.sdk.winsock2'
local M = {}

function M.ping(addr, timeout)
    local h = iphlp.IcmpCreateFile()
    if h == ffi.cast("HANDLE", -1) then return false end
    
    local rep = ffi.new("uint8_t[1024]")
    local ip = ws2.inet_addr(addr)
    
    -- [FIX] Restore timeout parameter (default 1000ms)
    local t = timeout or 1000
    local r = iphlp.IcmpSendEcho(h, ip, nil, 0, nil, rep, 1024, t)
    
    iphlp.IcmpCloseHandle(h)
    return r > 0
end

return M