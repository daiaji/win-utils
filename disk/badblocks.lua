local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

local function fill(buf, size, pattern)
    for i = 0, size - 1 do buf[i] = pattern end
end

-- 完整的读写验证逻辑
-- @param drive: PhysicalDrive 对象
-- @param cb: 进度回调
-- @param stop_on_error: 遇错即停
-- @param patterns: 写入模式数组 (e.g. {0xAA, 0x55})，若为 nil 则只读
function M.check(drive, cb, stop_on_error, patterns)
    if not drive then return false, "Invalid drive" end
    
    -- 默认只读模式
    if not patterns or #patterns == 0 then patterns = { "READ" } end
    
    local bs = 512 * 1024 -- 512KB Block
    local pMem = kernel32.VirtualAlloc(nil, bs, 0x1000, 0x04)
    if not pMem then return false, "Alloc failed" end
    ffi.gc(pMem, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    local pVerify = nil
    -- 如果有写入测试，分配验证缓冲区
    if type(patterns[1]) == "number" then
        pVerify = kernel32.VirtualAlloc(nil, bs, 0x1000, 0x04)
        if not pVerify then return false, "Alloc verify failed" end
        ffi.gc(pVerify, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    end
    
    local total = drive.size
    local stats = { bad = 0, read = 0, write = 0, corrupt = 0 }
    local rw_bytes = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    local success = true
    local msg = nil
    
    for pass_idx, pat in ipairs(patterns) do
        local is_write = (type(pat) == "number")
        local done = 0
        
        if is_write then fill(ffi.cast("uint8_t*", pMem), bs, pat) end
        
        li.QuadPart = 0
        kernel32.SetFilePointerEx(drive:get(), li, nil, C.FILE_BEGIN)
        
        while done < total do
            local chunk = math.min(bs, total - done)
            if chunk % drive.sector_size ~= 0 then 
                chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
            end
            
            local block_fail = false
            
            -- Write Phase
            if is_write then
                if kernel32.WriteFile(drive:get(), pMem, chunk, rw_bytes, nil) == 0 or rw_bytes[0] ~= chunk then
                    stats.write = stats.write + 1
                    stats.bad = stats.bad + 1
                    block_fail = true
                    if stop_on_error then success = false; msg = "Write error"; break end
                    -- 重置指针以便读取
                    li.QuadPart = done + chunk
                    kernel32.SetFilePointerEx(drive:get(), li, nil, C.FILE_BEGIN)
                else
                    -- Rewind for verify
                    li.QuadPart = done
                    kernel32.SetFilePointerEx(drive:get(), li, nil, C.FILE_BEGIN)
                end
            end
            
            -- Read/Verify Phase
            if not block_fail then
                local dest = is_write and pVerify or pMem
                if kernel32.ReadFile(drive:get(), dest, chunk, rw_bytes, nil) == 0 or rw_bytes[0] ~= chunk then
                    stats.read = stats.read + 1
                    stats.bad = stats.bad + 1
                    if stop_on_error then success = false; msg = "Read error"; break end
                    
                    li.QuadPart = done + chunk
                    kernel32.SetFilePointerEx(drive:get(), li, nil, C.FILE_BEGIN)
                else
                    if is_write and ffi.C.memcmp(pMem, pVerify, chunk) ~= 0 then
                        stats.corrupt = stats.corrupt + 1
                        stats.bad = stats.bad + 1
                        if stop_on_error then success = false; msg = "Corruption detected"; break end
                    end
                end
            end
            
            done = done + chunk
            local total_prog = ((pass_idx - 1) * total + done) / (total * #patterns)
            
            if cb and not cb(total_prog, stats.bad, stats.read, stats.write, stats.corrupt) then
                success = false; msg = "Cancelled"; break
            end
        end
        if not success then break end
    end
    
    ffi.gc(pMem, nil); kernel32.VirtualFree(pMem, 0, 0x8000)
    if pVerify then ffi.gc(pVerify, nil); kernel32.VirtualFree(pVerify, 0, 0x8000) end
    
    return success, msg, stats
end

return M