local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local M = {}

-- patterns: array of bytes, e.g., {0x55, 0xAA, 0x00}. If nil, read-only.
function M.check(drive, cb, stop_on_error, patterns)
    local buf_size = 1024 * 1024 -- 1MB
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then return false, "Alloc failed" end
    
    -- Verify buffer if writing
    local buf_v = nil
    if patterns and #patterns > 0 then
        buf_v = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    end
    
    local total = drive.size
    local r_bytes = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    
    -- Default to read-only scan if no patterns
    if not patterns or #patterns == 0 then patterns = { "READ" } end
    
    local success = true
    local msg = nil
    
    for _, pat in ipairs(patterns) do
        local is_write = (type(pat) == "number")
        local pos = 0
        
        if is_write then ffi.fill(buf, buf_size, pat) end
        
        while pos < total do
            local chunk = math.min(buf_size, total - pos)
            -- Align chunk
            if chunk % drive.sector_size ~= 0 then 
                chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
            end
            
            li.QuadPart = pos
            kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
            
            if is_write then
                if kernel32.WriteFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = "Write error at " .. pos; break
                end
                
                -- Verify
                li.QuadPart = pos
                kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
                if kernel32.ReadFile(drive.handle, buf_v, chunk, r_bytes, nil) == 0 then
                    success = false; msg = "Read back error at " .. pos; break
                end
                if ffi.C.memcmp(buf, buf_v, chunk) ~= 0 then
                    success = false; msg = "Corruption at " .. pos; break
                end
            else
                if kernel32.ReadFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = "Read error at " .. pos; break
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