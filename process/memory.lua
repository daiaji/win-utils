local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'

local M = {}

-- [Restored] Helper for readable protection strings
local function format_protect(p)
    local s = {}
    if bit.band(p, 0x01) ~= 0 then table.insert(s, "N") end -- NOACCESS
    if bit.band(p, 0x02) ~= 0 then table.insert(s, "R") end -- READONLY
    if bit.band(p, 0x04) ~= 0 then table.insert(s, "RW") end -- READWRITE
    if bit.band(p, 0x08) ~= 0 then table.insert(s, "WC") end -- WRITECOPY
    if bit.band(p, 0x10) ~= 0 then table.insert(s, "X") end -- EXECUTE
    if bit.band(p, 0x20) ~= 0 then table.insert(s, "RX") end -- EXECUTE_READ
    if bit.band(p, 0x40) ~= 0 then table.insert(s, "RWX") end -- EXECUTE_READWRITE
    if bit.band(p, 0x80) ~= 0 then table.insert(s, "WCX") end -- EXECUTE_WRITECOPY
    if bit.band(p, 0x100) ~= 0 then table.insert(s, "+G") end -- GUARD
    if bit.band(p, 0x200) ~= 0 then table.insert(s, "+NC") end -- NOCACHE
    return table.concat(s, "")
end

function M.read(pid, addr, size)
    local h = kernel32.OpenProcess(0x10, false, pid) -- VM_READ
    if not h then return nil end
    local buf = ffi.new("uint8_t[?]", size)
    local read = ffi.new("size_t[1]")
    local res = kernel32.ReadProcessMemory(h, ffi.cast("void*", addr), buf, size, read)
    kernel32.CloseHandle(h)
    if res == 0 then return nil end
    return ffi.string(buf, read[0])
end

function M.list_regions(pid)
    local h = kernel32.OpenProcess(0x400, false, pid) -- QUERY_INFO
    if not h then return {} end
    
    local list = {}
    local addr = 0
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    
    local name_buf_size = 1024
    local name_buf = ffi.new("uint8_t[?]", name_buf_size)
    local ret_len = ffi.new("size_t[1]")
    
    while true do
        if ntdll.NtQueryVirtualMemory(h, ffi.cast("void*", addr), 0, mbi, ffi.sizeof(mbi), nil) < 0 then
            break
        end
        
        local info = {
            base = tonumber(ffi.cast("uintptr_t", mbi.BaseAddress)),
            size = tonumber(mbi.RegionSize),
            state = tonumber(mbi.State),
            protect = tonumber(mbi.Protect),
            type = tonumber(mbi.Type),
            protect_str = format_protect(tonumber(mbi.Protect)), -- [Restored]
            filename = nil
        }
        
        if info.state == 0x1000 and (info.type == 0x40000 or info.type == 0x1000000) then
            if ntdll.NtQueryVirtualMemory(h, mbi.BaseAddress, 2, name_buf, name_buf_size, ret_len) >= 0 then
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