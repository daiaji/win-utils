local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- Page Protection Flags Mapping
M.PROTECT = {
    NOACCESS          = 0x01,
    READONLY          = 0x02,
    READWRITE         = 0x04,
    WRITECOPY         = 0x08,
    EXECUTE           = 0x10,
    EXECUTE_READ      = 0x20,
    EXECUTE_READWRITE = 0x40,
    EXECUTE_WRITECOPY = 0x80,
    GUARD             = 0x100,
    NOCACHE           = 0x200,
    WRITECOMBINE      = 0x400,
}

-- Memory State Flags
M.STATE = {
    COMMIT   = 0x1000,
    RESERVE  = 0x2000,
    FREE     = 0x10000,
}

-- Memory Type Flags
M.TYPE = {
    PRIVATE = 0x20000,
    MAPPED  = 0x40000,
    IMAGE   = 0x1000000,
}

local function format_protect(p)
    local s = {}
    if bit.band(p, M.PROTECT.NOACCESS) ~= 0 then table.insert(s, "N") end
    if bit.band(p, M.PROTECT.READONLY) ~= 0 then table.insert(s, "R") end
    if bit.band(p, M.PROTECT.READWRITE) ~= 0 then table.insert(s, "RW") end
    if bit.band(p, M.PROTECT.WRITECOPY) ~= 0 then table.insert(s, "WC") end
    if bit.band(p, M.PROTECT.EXECUTE) ~= 0 then table.insert(s, "X") end
    if bit.band(p, M.PROTECT.EXECUTE_READ) ~= 0 then table.insert(s, "RX") end
    if bit.band(p, M.PROTECT.EXECUTE_READWRITE) ~= 0 then table.insert(s, "RWX") end
    if bit.band(p, M.PROTECT.EXECUTE_WRITECOPY) ~= 0 then table.insert(s, "WCX") end
    if bit.band(p, M.PROTECT.GUARD) ~= 0 then table.insert(s, "+G") end
    if bit.band(p, M.PROTECT.NOCACHE) ~= 0 then table.insert(s, "+NC") end
    return table.concat(s, "")
end

-- Reference: phlib/native.c : PhEnumVirtualMemory
function M.list_regions(pid)
    local hProcess = kernel32.OpenProcess(C.PROCESS_QUERY_INFORMATION, false, pid)
    if not hProcess or hProcess == ffi.cast("HANDLE", -1) then 
        -- Try limited info for tighter security contexts
        hProcess = kernel32.OpenProcess(0x1000, false, pid) -- PROCESS_QUERY_LIMITED_INFORMATION
        if not hProcess or hProcess == ffi.cast("HANDLE", -1) then
            return nil, util.format_error()
        end
    end
    hProcess = Handle.guard(hProcess)

    local regions = {}
    local address = ffi.cast("void*", 0)
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    local ret_len = ffi.new("size_t[1]")
    
    -- Buffer for filename queries (allocated once reuse)
    local filename_buf_size = 1024
    local filename_buf = ffi.new("uint8_t[?]", filename_buf_size)
    
    while true do
        local status = ntdll.NtQueryVirtualMemory(
            hProcess,
            address,
            C.MemoryBasicInformation, -- [FIXED] Use C namespace
            mbi,
            ffi.sizeof(mbi),
            ret_len
        )

        if status < 0 then break end

        -- Save Region Info
        local info = {
            base_address = tonumber(ffi.cast("uintptr_t", mbi.BaseAddress)),
            allocation_base = tonumber(ffi.cast("uintptr_t", mbi.AllocationBase)),
            size = tonumber(mbi.RegionSize),
            state = tonumber(mbi.State),
            protect = tonumber(mbi.Protect),
            type = tonumber(mbi.Type),
            protect_str = format_protect(tonumber(mbi.Protect)),
            filename = nil
        }

        -- [NEW] Fetch Filename for Mapped/Image types
        if info.state ~= M.STATE.FREE and 
           (info.type == M.TYPE.MAPPED or info.type == M.TYPE.IMAGE) then
            
            local f_status = ntdll.NtQueryVirtualMemory(
                hProcess,
                address,
                C.MemoryMappedFilenameInformation, -- [FIXED] Use C namespace
                filename_buf,
                filename_buf_size,
                ret_len
            )
            
            if f_status == 0 then
                local us = ffi.cast("UNICODE_STRING*", filename_buf)
                if us.Buffer ~= nil and us.Length > 0 then
                    info.filename = util.from_wide(us.Buffer, us.Length / 2)
                end
            end
        end

        table.insert(regions, info)

        -- Calculate next address
        -- Native pointer arithmetic required for 64-bit safety
        address = ffi.cast("uint8_t*", mbi.BaseAddress) + mbi.RegionSize
        address = ffi.cast("void*", address)
    end

    return regions
end

return M