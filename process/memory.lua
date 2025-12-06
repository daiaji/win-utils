local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

local function format_protect(p)
    local s = {}
    if bit.band(p, 0x01) ~= 0 then table.insert(s, "N") end 
    if bit.band(p, 0x02) ~= 0 then table.insert(s, "R") end 
    if bit.band(p, 0x04) ~= 0 then table.insert(s, "RW") end
    if bit.band(p, 0x10) ~= 0 then table.insert(s, "X") end
    if bit.band(p, 0x20) ~= 0 then table.insert(s, "RX") end 
    if bit.band(p, 0x40) ~= 0 then table.insert(s, "RWX") end
    return table.concat(s, "")
end

function M.read(pid, addr, size)
    local h = kernel32.OpenProcess(0x10, false, pid) -- VM_READ
    if not h then return nil, util.last_error() end
    local buf = ffi.new("uint8_t[?]", size)
    local read = ffi.new("size_t[1]")
    local res = kernel32.ReadProcessMemory(h, ffi.cast("void*", addr), buf, size, read)
    kernel32.CloseHandle(h)
    if res == 0 then return nil, util.last_error() end
    return ffi.string(buf, read[0])
end

function M.list_regions(pid)
    local h = kernel32.OpenProcess(0x400, false, pid) 
    if not h then return nil, util.last_error() end
    
    local list = {}
    local addr = 0
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    local name_buf = ffi.new("uint8_t[1024]")
    local ret_len = ffi.new("size_t[1]")
    
    while true do
        if ntdll.NtQueryVirtualMemory(h, ffi.cast("void*", addr), 0, mbi, ffi.sizeof(mbi), nil) < 0 then
            break
        end
        
        local info = {
            addr = tonumber(ffi.cast("uintptr_t", mbi.BaseAddress)),
            size = tonumber(mbi.RegionSize),
            state = tonumber(mbi.State),
            protect = tonumber(mbi.Protect),
            type = tonumber(mbi.Type),
            protect_str = format_protect(tonumber(mbi.Protect))
        }
        
        if info.state == 0x1000 and (info.type == 0x40000 or info.type == 0x1000000) then
            if ntdll.NtQueryVirtualMemory(h, mbi.BaseAddress, 2, name_buf, 1024, ret_len) >= 0 then
                local us = ffi.cast("UNICODE_STRING*", name_buf)
                if us.Buffer ~= nil and us.Length > 0 then
                    info.filename = util.from_wide(us.Buffer, us.Length / 2)
                end
            end
        end
        
        table.insert(list, info)
        addr = ffi.cast("uintptr_t", mbi.BaseAddress) + mbi.RegionSize
    end
    
    kernel32.CloseHandle(h)
    return list
end

return M