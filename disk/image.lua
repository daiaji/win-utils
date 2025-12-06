local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 将镜像文件写入驱动器
function M.write(img_path, drive, cb)
    local f, err = native.open_file(img_path, "r")
    if not f then return false, "Open image failed: " .. tostring(err) end
    
    local buf_size = 1024 * 1024
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then f:close(); return false, util.last_error("VirtualAlloc failed") end
    
    local read_bytes = ffi.new("DWORD[1]")
    local pos = 0
    local size = ffi.new("LARGE_INTEGER")
    kernel32.GetFileSizeEx(f:get(), size)
    local total = tonumber(size.QuadPart)
    
    local ok = true
    local err_msg = nil
    
    while pos < total do
        if kernel32.ReadFile(f:get(), buf, buf_size, read_bytes, nil) == 0 then 
            ok = false; err_msg = util.last_error("Read file failed"); break 
        end
        
        local bytes = read_bytes[0]
        if bytes == 0 then break end
        
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
function M.read(drive, img_path, cb)
    -- CREATE_ALWAYS = 2, FILE_ATTRIBUTE_NORMAL = 0x80
    local f = native.open_internal(img_path, 0x40000000, 0, 2, 0x80) 
    if not f then return false, util.last_error("Create image failed") end
    
    local buf_size = 1024 * 1024
    local buf = kernel32.VirtualAlloc(nil, buf_size, 0x1000, 4)
    if not buf then f:close(); return false, util.last_error("VirtualAlloc failed") end
    
    local total = drive.size
    local pos = 0
    local written = ffi.new("DWORD[1]")
    local ok = true
    local err_msg = nil
    
    while pos < total do
        local chunk = math.min(buf_size, total - pos)
        if chunk % drive.sector_size ~= 0 then 
            chunk = math.ceil(chunk / drive.sector_size) * drive.sector_size 
        end
        
        local data = drive:read(pos, chunk)
        if not data then 
            ok = false; err_msg = "Read drive failed"; break 
        end
        
        local valid_len = math.min(#data, total - pos)
        
        if kernel32.WriteFile(f:get(), data, valid_len, written, nil) == 0 then
            ok = false; err_msg = util.last_error("Write file failed"); break
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