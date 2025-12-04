local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- 烧录镜像 (DD 模式)
-- @param image_path: 镜像文件路径
-- @param drive: PhysicalDrive 对象 (必须已 lock)
-- @param cb: 进度回调 function(percent)
function M.burn_dd(image_path, drive, cb)
    if not drive or not drive.handle then return false, "Invalid drive" end
    
    local hFile = kernel32.CreateFileW(util.to_wide(image_path), C.GENERIC_READ, C.FILE_SHARE_READ, nil, C.OPEN_EXISTING, 0, nil)
    if hFile == ffi.cast("HANDLE", -1) then return false, "Open image failed" end
    -- [FIX] Handle(hFile)
    local fileObj = Handle(hFile)
    
    local size_li = ffi.new("LARGE_INTEGER")
    kernel32.GetFileSizeEx(hFile, size_li)
    local total = tonumber(size_li.QuadPart)
    
    local buf_size = 1024 * 1024 -- 1MB Chunk
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 0x04)
    ffi.gc(buf, function(p) kernel32.VirtualFree(p, 0, 0x8000) end)
    
    local read = ffi.new("DWORD[1]")
    local processed = 0
    local ok = true
    local msg = nil
    
    while processed < total do
        if kernel32.ReadFile(hFile, buf, buf_size, read, nil) == 0 then
            ok = false; msg = "Read error"; break
        end
        if read[0] == 0 then break end
        
        -- 对齐检查 (PhysicalDrive.write_sectors 要求对齐)
        local data_len = read[0]
        local padding = 0
        if data_len % drive.sector_size ~= 0 then
            padding = drive.sector_size - (data_len % drive.sector_size)
            -- Zero pad the buffer end if needed
            ffi.fill(ffi.cast("uint8_t*", buf) + data_len, padding, 0)
        end
        
        local chunk_data = ffi.string(buf, data_len + padding)
        if not drive:write_sectors(processed, chunk_data) then
            ok = false; msg = "Write error"; break
        end
        
        processed = processed + read[0]
        if cb and not cb(processed / total) then ok = false; msg = "Cancelled"; break end
    end
    
    fileObj:close()
    ffi.gc(buf, nil); kernel32.VirtualFree(buf, 0, 0x8000)
    return ok, msg
end

return M