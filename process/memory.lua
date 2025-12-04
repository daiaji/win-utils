local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local Handle = require 'win-utils.core.handle'

local M = {}

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
    local h = kernel32.OpenProcess(0x400, false, pid)
    if not h then return {} end
    local list, addr = {}, 0
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    while ntdll.NtQueryVirtualMemory(h, ffi.cast("void*", addr), 0, mbi, ffi.sizeof(mbi), nil) >= 0 do
        table.insert(list, {
            base = tonumber(ffi.cast("uintptr_t", mbi.BaseAddress)),
            size = tonumber(mbi.RegionSize),
            state = tonumber(mbi.State),
            protect = tonumber(mbi.Protect),
            type = tonumber(mbi.Type)
        })
        addr = ffi.cast("uintptr_t", mbi.BaseAddress) + mbi.RegionSize
    end
    kernel32.CloseHandle(h)
    return list
end

return M