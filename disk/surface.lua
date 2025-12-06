local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 表面扫描 (原 badblocks)
-- @param drive: PhysicalDrive 对象
-- @param cb: 进度回调
-- @param mode: "read" (默认), "write" (破坏性)
-- @param patterns: 自定义模式字节数组 (可选)
function M.scan(drive, cb, mode, patterns)
    local is_write = (mode == "write")
    local buf_size = 1024 * 1024 -- 1MB
    
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then return false, "Alloc failed" end
    
    -- 验证缓冲区 (仅写入模式)
    local buf_v = nil
    if is_write then
        buf_v = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    end
    
    local total = drive.size
    local r_bytes = ffi.new("DWORD[1]")
    local li = ffi.new("LARGE_INTEGER")
    
    -- 默认扫描模式
    local active_patterns = patterns
    if not active_patterns or #active_patterns == 0 then
        if is_write then active_patterns = { 0x55, 0xAA } -- 01010101, 10101010
        else active_patterns = { "READ" } end
    end
    
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
                -- 写入
                if kernel32.WriteFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = "Write error at " .. pos; break
                end
                
                -- 回读验证
                li.QuadPart = pos
                kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
                if kernel32.ReadFile(drive.handle, buf_v, chunk, r_bytes, nil) == 0 then
                    success = false; msg = "Read back error at " .. pos; break
                end
                if ffi.C.memcmp(buf, buf_v, chunk) ~= 0 then
                    success = false; msg = "Corruption at " .. pos; break
                end
            else
                -- 纯读取
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