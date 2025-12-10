local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local c_string = require 'ffi.req' 'c.string'

local M = {}

-- [RESTORED] Detailed statistics & Error handling options
-- opts: { stop_on_error = boolean }
-- returns: success, msg, stats_table
function M.scan(drive, cb, mode, patterns, opts)
    opts = opts or {}
    local stop_on_error = opts.stop_on_error
    
    local stats = {
        read_errors = 0,
        write_errors = 0,
        corrupt_errors = 0,
        bad_blocks = 0
    }
    
    local is_write = (mode == "write")
    local buf_size = 1024 * 1024 
    
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then return false, util.last_error("VirtualAlloc failed"), stats end
    
    local buf_v = nil
    if is_write then
        buf_v = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
        if not buf_v then 
            kernel32.VirtualFree(buf, 0, 0x8000)
            return false, util.last_error("VirtualAlloc verify buf failed"), stats
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
            
            local block_fail = false
            
            if is_write then
                if kernel32.WriteFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    stats.write_errors = stats.write_errors + 1
                    stats.bad_blocks = stats.bad_blocks + 1
                    block_fail = true
                    if stop_on_error then success = false; msg = util.last_error("Write error at " .. pos); break end
                else
                    -- Verify
                    li.QuadPart = pos
                    kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
                    if kernel32.ReadFile(drive.handle, buf_v, chunk, r_bytes, nil) == 0 then
                        stats.read_errors = stats.read_errors + 1
                        stats.bad_blocks = stats.bad_blocks + 1
                        block_fail = true
                        if stop_on_error then success = false; msg = util.last_error("Read back error at " .. pos); break end
                    else
                        if c_string.memcmp(buf, buf_v, chunk) ~= 0 then
                            stats.corrupt_errors = stats.corrupt_errors + 1
                            stats.bad_blocks = stats.bad_blocks + 1
                            block_fail = true
                            if stop_on_error then success = false; msg = "Data Corruption at " .. pos; break end
                        end
                    end
                end
            else
                -- Read Test
                if kernel32.ReadFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    stats.read_errors = stats.read_errors + 1
                    stats.bad_blocks = stats.bad_blocks + 1
                    block_fail = true
                    if stop_on_error then success = false; msg = util.last_error("Read error at " .. pos); break end
                end
            end
            
            pos = pos + chunk
            if cb and not cb(pos/total, stats) then 
                success = false; msg = "Cancelled"; break 
            end
        end
        if not success then break end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    if buf_v then kernel32.VirtualFree(buf_v, 0, 0x8000) end
    
    return success, msg, stats
end

return M