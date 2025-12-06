local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'
local M = {}

-- [API] 将镜像文件写入驱动器
-- @param img_path: 源镜像文件路径
-- @param drive: 目标 PhysicalDrive 对象
-- @param cb: 进度回调 function(percent)
function M.write(img_path, drive, cb)
    local f = native.open_file(img_path, "r")
    if not f then return false, "Open image failed" end
    
    local buf_size = 1024 * 1024 -- 1MB
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then f:close(); return false, "Alloc failed" end
    
    local read_bytes = ffi.new("DWORD[1]")
    local pos = 0
    local size = ffi.new("LARGE_INTEGER")
    kernel32.GetFileSizeEx(f:get(), size)
    local total = tonumber(size.QuadPart)
    
    local ok = true
    local err_msg = nil
    
    while pos < total do
        if kernel32.ReadFile(f:get(), buf, buf_size, read_bytes, nil) == 0 then 
            ok = false; err_msg = "Read file failed: " .. util.last_error(); break 
        end
        
        local bytes = read_bytes[0]
        if bytes == 0 then break end
        
        -- 调用物理驱动器的低级写入
        local w_ok, w_err = drive:write(pos, buf, bytes)
        if not w_ok then 
            ok = false; err_msg = "Write drive failed: " .. tostring(w_err); break 
        end
        
        pos = pos + bytes
        if cb then 
            if not cb(pos/total) then ok = false; err_msg = "Cancelled"; break end
        end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    f:close()
    return ok, err_msg
end

-- [API] 从驱动器读取到镜像文件 (Dump)
-- @param drive: 源 PhysicalDrive 对象
-- @param img_path: 目标文件路径
-- @param cb: 进度回调
function M.read(drive, img_path, cb)
    local f = native.open_file(img_path, "w")
    if not f then return false, "Create image failed" end
    
    local buf_size = 1024 * 1024
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then f:close(); return false, "Alloc failed" end
    
    local total = drive.size
    local pos = 0
    local written = ffi.new("DWORD[1]")
    local ok = true
    local err_msg = nil
    
    while pos < total do
        local chunk = math.min(buf_size, total - pos)
        
        -- 对齐读取
        if chunk % drive.sector_size ~= 0 then 
            chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
        end
        
        local data = drive:read(pos, chunk)
        if not data then 
            ok = false; err_msg = "Read drive failed"; break 
        end
        
        -- 截断多余的对齐数据
        local valid_len = math.min(#data, total - pos)
        
        if kernel32.WriteFile(f:get(), data, valid_len, written, nil) == 0 then
            ok = false; err_msg = "Write file failed"; break
        end
        
        pos = pos + valid_len
        if cb then
            if not cb(pos/total) then ok = false; err_msg = "Cancelled"; break end
        end
    end
    
    kernel32.VirtualFree(buf, 0, 0x8000)
    f:close()
    return ok, err_msg
end

return M