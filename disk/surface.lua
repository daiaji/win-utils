local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

ffi.cdef [[
    int memcmp(const void *ptr1, const void *ptr2, size_t num);
]]

local M = {}

-- [Rufus Port] 生成测试图案
local function fill_buffer(buf, size, pattern_type, offset_base, sector_size)
    local ptr = ffi.cast("uint8_t*", buf)
    
    if pattern_type == "random" then
        for i=0, size-1 do ptr[i] = math.random(0, 255) end
    else
        local val = (pattern_type == "00") and 0x00 or 
                    (pattern_type == "FF") and 0xFF or 
                    (pattern_type == "55") and 0x55 or 
                    (pattern_type == "AA") and 0xAA or 0x55
        ffi.fill(ptr, size, val)
    end
    
    -- [Rufus Logic] 写入扇区索引以检测 Fake Drive
    if offset_base then
        local u64_ptr = ffi.cast("uint64_t*", buf)
        local num_sectors = size / sector_size
        local magic_offset = 0 -- 通常放在开头
        for i=0, num_sectors-1 do
            -- 每个扇区写入其 LBA 地址
            local lba = (offset_base / sector_size) + i
            -- 写入到扇区的前8个字节
            local sector_start = ffi.cast("uint64_t*", ptr + (i * sector_size))
            sector_start[0] = ffi.cast("uint64_t", lba)
        end
    end
end

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
    
    -- 默认模式：如果是写测试，使用 0x55 (Rufus 常用)
    local active_patterns = patterns or (is_write and { "55" } or { "READ" })
    
    local success = true
    local msg = nil
    
    for _, pat in ipairs(active_patterns) do
        local pos = 0
        
        if is_write then
            -- [Rufus] 每次模式填充一次大缓存，不需要每次循环都填，除非是 Fake Check
            -- 这里为了简单，我们只填一次 Pattern，但在循环里更新 LBA
            fill_buffer(buf, buf_size, pat, nil, drive.sector_size)
        end
        
        while pos < total do
            local chunk = math.min(buf_size, total - pos)
            if chunk % drive.sector_size ~= 0 then 
                chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
            end
            
            li.QuadPart = pos
            kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
            
            if is_write then
                -- [Rufus] 更新 LBA 标记
                fill_buffer(buf, chunk, pat, pos, drive.sector_size)
                
                if kernel32.WriteFile(drive.handle, buf, chunk, r_bytes, nil) == 0 then
                    success = false; msg = util.last_error("Write error at " .. pos); break
                end
                
                -- 读回验证
                li.QuadPart = pos
                kernel32.SetFilePointerEx(drive.handle, li, nil, 0)
                if kernel32.ReadFile(drive.handle, buf_v, chunk, r_bytes, nil) == 0 then
                    success = false; msg = util.last_error("Read back error at " .. pos); break
                end
                if ffi.C.memcmp(buf, buf_v, chunk) ~= 0 then
                    success = false; msg = "Data Corruption (Verification Mismatch) at " .. pos; break
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