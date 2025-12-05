local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
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
    -- QUERY_INFORMATION(0x400) needed for NtQueryVirtualMemory? No, usually just requires handle access.
    -- But to be safe in PE, we use OpenProcess.
    local h = kernel32.OpenProcess(0x400, false, pid)
    if not h then return {} end
    
    local list = {}
    local addr = 0
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    
    -- Buffer for filename (MemoryMappedFilenameInformation)
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
            filename = nil
        }
        
        -- [Restored] 获取映射文件名 (仅针对 MEM_MAPPED 或 MEM_IMAGE 且已提交的区域)
        if info.state == 0x1000 and (info.type == 0x40000 or info.type == 0x1000000) then
            -- MemoryMappedFilenameInformation = 2
            if ntdll.NtQueryVirtualMemory(h, mbi.BaseAddress, 2, name_buf, name_buf_size, ret_len) >= 0 then
                local us = ffi.cast("UNICODE_STRING*", name_buf)
                if us.Buffer ~= nil and us.Length > 0 then
                    info.filename = util.from_wide(us.Buffer, us.Length / 2)
                end
            end
        end
        
        table.insert(list, info)
        
        -- Calculate next address
        addr = ffi.cast("uintptr_t", mbi.BaseAddress) + mbi.RegionSize
    end
    
    kernel32.CloseHandle(h)
    return list
end

return M