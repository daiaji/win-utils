local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

M.PROTECT = {
    NOACCESS=1, READONLY=2, READWRITE=4, WRITECOPY=8, EXECUTE=0x10,
    EXECUTE_READ=0x20, EXECUTE_READWRITE=0x40, EXECUTE_WRITECOPY=0x80,
    GUARD=0x100, NOCACHE=0x200, WRITECOMBINE=0x400
}

local function format_protect(p)
    local s = {}
    if bit.band(p, 1)~=0 then table.insert(s,"N") end
    if bit.band(p, 2)~=0 then table.insert(s,"R") end
    if bit.band(p, 4)~=0 then table.insert(s,"RW") end
    if bit.band(p, 8)~=0 then table.insert(s,"WC") end
    if bit.band(p, 0x10)~=0 then table.insert(s,"X") end
    if bit.band(p, 0x20)~=0 then table.insert(s,"RX") end
    if bit.band(p, 0x40)~=0 then table.insert(s,"RWX") end
    if bit.band(p, 0x80)~=0 then table.insert(s,"WCX") end
    if bit.band(p, 0x100)~=0 then table.insert(s,"+G") end
    if bit.band(p, 0x200)~=0 then table.insert(s,"+NC") end
    return table.concat(s, "")
end

function M.list_regions(pid)
    local hProc = kernel32.OpenProcess(0x1000, false, pid)
    if not hProc then hProc = kernel32.OpenProcess(0x400, false, pid) end
    if not hProc or hProc == ffi.cast("HANDLE", -1) then return nil end
    -- [FIX] Handle(hProc)
    local safe = Handle(hProc)
    
    local res = {}
    local addr = ffi.cast("void*", 0)
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    local ret = ffi.new("size_t[1]")
    
    while ntdll.NtQueryVirtualMemory(hProc, addr, 0, mbi, ffi.sizeof(mbi), ret) >= 0 do
        local item = {
            base = tonumber(ffi.cast("uintptr_t", mbi.BaseAddress)),
            size = tonumber(mbi.RegionSize),
            state = tonumber(mbi.State),
            protect = tonumber(mbi.Protect),
            type = tonumber(mbi.Type),
            protect_str = format_protect(tonumber(mbi.Protect))
        }
        
        if item.state ~= 0x10000 and (item.type == 0x40000 or item.type == 0x1000000) then
            local fbuf = ffi.new("uint8_t[1024]")
            local fret = ffi.new("size_t[1]")
            if ntdll.NtQueryVirtualMemory(hProc, addr, 2, fbuf, 1024, fret) >= 0 then
                local us = ffi.cast("UNICODE_STRING*", fbuf)
                if us.Buffer ~= nil then item.filename = util.from_wide(us.Buffer, us.Length/2) end
            end
        end
        
        table.insert(res, item)
        addr = ffi.cast("uint8_t*", mbi.BaseAddress) + mbi.RegionSize
    end
    return res
end

return M