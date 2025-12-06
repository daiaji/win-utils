local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

ffi.cdef [[
    int memcmp(const void *ptr1, const void *ptr2, size_t num);
]]

local M = {}

-- [API] 表面扫描 (原 badblocks)
function M.scan(drive, cb, mode, patterns)
    local is_write = (mode == "write")
    local buf_size = 1024 * 1024 
    
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then return false, util.last_error("VirtualAlloc failed") end
    
    local buf_v = nil
    if is_write then
        buf_v = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
        if not buf_v then 
            kernel32.VirtualFree(buf, 0, 0x8000)
            return false, util.last_error("VirtualAlloc verify buf failed")
        end
    end
    
    local total = drive.size
    local r_bytes = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    local active_patterns = patterns or (is_write and { 0x55, 0xAA } or { "READ" })
    
    local success = true
    local msg = nil
    
    for _, pat in ipairs(active_patterns) do
        local pat_val = (type(pat) == "number") and pat or nil
        local pos = 0
        
        if pat_val then ffi.fill(buf, buf_size, pat_val) end
        
        while pos < total do
            local chunk = math.min(buf_size, total - pos)
            if chunk % drive.sector_size ~= 0 then 
                chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
            end
            
            li.QuadPart = pos
            kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
            
            if is_write then
                if kernel32.WriteFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = util.last_error("Write error at " .. pos); break
                end
                
                li.QuadPart = pos
                kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
                if kernel32.ReadFile(drive.handle, buf_v, chunk, r_bytes, nil) == 0 then
                    success = false; msg = util.last_error("Read back error at " .. pos); break
                end
                if ffi.C.memcmp(buf, buf_v, chunk) ~= 0 then
                    success = false; msg = "Data Corruption at " .. pos; break
                end
            else
                if kernel32.ReadFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = util.last_error("Read error at " .. pos); break
                end
            end
            
            pos = pos + chunk
            if cb and not cb(pos/total) then success = false; msg = "Cancelled"; break end
        end
        if not success then break end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    if buf_v then kernel32.VirtualFree(buf_v, 0, 0x8000) end
    
    return success, msg
end

return M