local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- Generates a test pattern buffer
local function fill_pattern(buf, size, pattern)
    for i = 0, size - 1 do
        buf[i] = pattern
    end
end

-- 坏块检测逻辑 (Enhanced: Supports Multi-Pass Write-Verify)
-- @param drive: 已打开并锁定的 PhysicalDrive 对象
-- @param progress_cb: function(percent, bad_count, read_errs, write_errs, corrupt_errs) return continue
-- @param stop_on_error: 遇到错误立即停止
-- @param write_patterns: table|nil (数组，例如 {0x55, 0xAA, 0x00, 0xFF}。如果不为 nil，则进行破坏性写入测试)
function M.check(drive, progress_cb, stop_on_error, write_patterns)
    if not drive then return false, "Invalid drive" end
    
    local block_size = 512 * 1024 -- 512KB Block Size (Matches Rufus)
    
    -- Allocate aligned buffers (Write Buffer)
    local pMem = kernel32.VirtualAlloc(nil, block_size, 0x1000, 0x04)
    if pMem == nil then return false, "VirtualAlloc failed" end
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    -- Allocate Verify Buffer (Read Buffer)
    local pVerify = nil
    if write_patterns then
        pVerify = kernel32.VirtualAlloc(nil, block_size, 0x1000, 0x04)
        if pVerify == nil then return false, "VirtualAlloc (verify) failed" end
        ffi.gc(pVerify, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    end
    
    local patterns = write_patterns or {}
    -- If no patterns provided and not writing, simulate one pass for reading
    if #patterns == 0 and not write_patterns then
        patterns = { "READ_ONLY" }
    end
    
    local total_size = drive.size
    local bad_blocks = 0
    local read_errors = 0
    local write_errors = 0
    local corrupt_errors = 0
    local success = true
    local err_msg = nil
    
    local bytes_transferred = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    
    -- Iterate over each pass
    for pass_idx, pattern_val in ipairs(patterns) do
        local is_write_pass = (type(pattern_val) == "number")
        local processed = 0
        
        -- Fill buffer if writing
        if is_write_pass then
            fill_pattern(ffi.cast("uint8_t*", pMem), block_size, pattern_val)
        end
        
        -- Seek to start for this pass
        li.QuadPart = 0
        if kernel32.SetFilePointerEx(drive.handle, li, nil, C.FILE_BEGIN) == 0 then
            success = false; err_msg = "Seek start failed"; break
        end
        
        while processed < total_size do
            local to_process = math.min(block_size, total_size - processed)
            local block_failed = false
            
            -- WRITE PHASE
            if is_write_pass then
                local res = kernel32.WriteFile(drive.handle, pMem, to_process, bytes_transferred, nil)
                
                if res == 0 or bytes_transferred[0] ~= to_process then
                    write_errors = write_errors + 1
                    bad_blocks = bad_blocks + 1
                    block_failed = true
                    if stop_on_error then
                        success = false; err_msg = "Write failed at " .. processed; break
                    end
                    
                    -- Reset pointer for read phase attempt (or skip)
                    li.QuadPart = processed + to_process
                    kernel32.SetFilePointerEx(drive.handle, li, nil, C.FILE_BEGIN)
                else
                    -- Rewind to read back
                    li.QuadPart = processed
                    kernel32.SetFilePointerEx(drive.handle, li, nil, C.FILE_BEGIN)
                end
            end
            
            if not success then break end
            
            -- READ / VERIFY PHASE
            if not block_failed then
                -- If we are in write mode, read into pVerify to compare with pMem
                -- If read only mode, read into pMem
                local dest_buf = is_write_pass and pVerify or pMem
                local res = kernel32.ReadFile(drive.handle, dest_buf, to_process, bytes_transferred, nil)
                
                if res == 0 or bytes_transferred[0] ~= to_process then
                    read_errors = read_errors + 1
                    bad_blocks = bad_blocks + 1
                    if stop_on_error then
                        success = false; err_msg = "Read failed at " .. processed; break
                    end
                    
                    li.QuadPart = processed + to_process
                    kernel32.SetFilePointerEx(drive.handle, li, nil, C.FILE_BEGIN)
                else
                    -- Verification (only if writing)
                    if is_write_pass then
                        if ffi.C.memcmp(pMem, pVerify, to_process) ~= 0 then
                            corrupt_errors = corrupt_errors + 1
                            bad_blocks = bad_blocks + 1
                            if stop_on_error then
                                success = false; err_msg = "Data corruption at " .. processed; break
                            end
                        end
                    end
                end
            end
            
            if not success then break end
            
            processed = processed + to_process
            
            -- Calculate total progress across all passes
            local overall_progress = ((pass_idx - 1) * total_size + processed) / (total_size * #patterns)
            
            if progress_cb then
                if not progress_cb(overall_progress, bad_blocks, read_errors, write_errors, corrupt_errors) then
                    success = false; err_msg = "Cancelled"; break
                end
            end
        end
        if not success then break end
    end
    
    ffi.gc(pMem, nil)
    kernel32.VirtualFree(pMem, 0, 0x8000)
    
    if pVerify then
        ffi.gc(pVerify, nil)
        kernel32.VirtualFree(pVerify, 0, 0x8000)
    end
    
    return success, err_msg, { 
        bad_blocks = bad_blocks, 
        read_errors = read_errors, 
        write_errors = write_errors,
        corrupt_errors = corrupt_errors 
    }
end

return M