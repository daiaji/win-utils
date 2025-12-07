local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'

local M = {}

-- 配置常量
local BUF_SIZE = 4 * 1024 * 1024 -- 4MB Buffer for optimal throughput

-- [Helper] 获取驱动器的 Raw Handle，绕过 physical.lua 的安全封装
local function get_raw_handle(drive)
    if type(drive) == "table" and drive.get then
        return drive:get()
    end
    return drive -- 假设传入的就是 cdata handle
end

-- [API] 将镜像文件写入驱动器 (DD Mode)
-- @param img_path: 源镜像文件路径
-- @param drive: 已打开并锁定的 PhysicalDrive 对象
-- @param cb: 进度回调 function(percentage) -> bool (返回 false 取消)
function M.write(img_path, drive, cb)
    local hDisk = get_raw_handle(drive)
    if not hDisk then return false, "Invalid drive handle" end

    -- 1. 打开源镜像 (Sequential Scan 优化)
    -- FILE_FLAG_SEQUENTIAL_SCAN (0x08000000)
    local f, err = native.open_internal(img_path, 0x80000000, 1, 3, 0x08000000) -- GENERIC_READ, ShareRead, OpenExisting
    if not f then return false, "Open image failed: " .. tostring(err) end

    -- 2. 分配对齐内存 (4MB)
    -- 使用 VirtualAlloc 确保内存页边界对齐，满足底层磁盘驱动要求
    local buf = kernel32.VirtualAlloc(nil, BUF_SIZE, 0x1000, 0x04) -- MEM_COMMIT, PAGE_READWRITE
    if not buf then 
        f:close()
        return false, util.last_error("VirtualAlloc failed") 
    end

    -- 3. 获取文件大小
    local fileSize = ffi.new("LARGE_INTEGER")
    if kernel32.GetFileSizeEx(f:get(), fileSize) == 0 then
        kernel32.VirtualFree(buf, 0, 0x8000)
        f:close()
        return false, util.last_error("GetFileSizeEx failed")
    end
    local total = tonumber(fileSize.QuadPart)

    -- 4. 准备变量
    local sector_size = drive.sector_size or 512
    local read_bytes = ffi.new("DWORD[1]")
    local write_bytes = ffi.new("DWORD[1]")
    local offset = ffi.new("LARGE_INTEGER")
    local pos = 0
    local ok = true
    local err_msg = nil

    -- 5. 高性能循环
    while pos < total do
        -- 5.1 读取镜像
        -- 即使是最后一块，我们也尝试读满 buf，ReadFile 会返回实际读取量
        if kernel32.ReadFile(f:get(), buf, BUF_SIZE, read_bytes, nil) == 0 then
            ok = false; err_msg = util.last_error("Read file failed"); break
        end

        local bytes_in = read_bytes[0]
        if bytes_in == 0 then break end -- EOF

        -- 5.2 扇区对齐处理 (Tail Padding)
        -- 物理磁盘写入必须是扇区大小的整数倍
        local bytes_to_write = bytes_in
        if bytes_in % sector_size ~= 0 then
            local padding = sector_size - (bytes_in % sector_size)
            -- 填充 buffer 尾部为 0
            ffi.fill(ffi.cast("uint8_t*", buf) + bytes_in, padding, 0)
            bytes_to_write = bytes_in + padding
        end

        -- 5.3 定位磁盘指针
        offset.QuadPart = pos
        if kernel32.SetFilePointerEx(hDisk, offset, nil, 0) == 0 then
            ok = false; err_msg = util.last_error("Seek disk failed"); break
        end

        -- 5.4 写入磁盘 (Direct Write)
        if kernel32.WriteFile(hDisk, buf, bytes_to_write, write_bytes, nil) == 0 then
            ok = false; err_msg = util.last_error("Write disk failed"); break
        end

        -- 验证写入量 (允许最后一块因为 Padding 而写入更多，但不允许更少)
        if write_bytes[0] < bytes_to_write then
            ok = false; err_msg = "Short write to disk"; break
        end

        -- 5.5 进度回调
        pos = pos + bytes_in -- 注意：进度按实际文件大小计算，不算 padding
        if cb then
            if not cb(pos / total) then 
                ok = false; err_msg = "Cancelled by user"; break 
            end
        end
    end

    -- 6. 清理
    kernel32.VirtualFree(buf, 0, 0x8000)
    f:close()
    
    -- 强制刷新缓冲区
    if ok then kernel32.FlushFileBuffers(hDisk) end

    return ok, err_msg
end

-- [API] 从驱动器读取到镜像文件 (Dump / Backup)
-- @param drive: 已打开的 PhysicalDrive 对象
-- @param img_path: 目标镜像路径
-- @param cb: 进度回调
function M.read(drive, img_path, cb)
    local hDisk = get_raw_handle(drive)
    if not hDisk then return false, "Invalid drive handle" end

    -- 1. 创建目标镜像 (Sequential Scan 优化)
    -- FILE_ATTRIBUTE_NORMAL (0x80) | FILE_FLAG_SEQUENTIAL_SCAN (0x08000000)
    local f, err = native.open_internal(img_path, 0x40000000, 0, 2, 0x08000080) -- GENERIC_WRITE, NoShare, CreateAlways
    if not f then return false, "Create image failed: " .. tostring(err) end

    -- 2. 分配对齐内存
    local buf = kernel32.VirtualAlloc(nil, BUF_SIZE, 0x1000, 0x04)
    if not buf then 
        f:close()
        return false, util.last_error("VirtualAlloc failed") 
    end

    -- 3. 准备变量
    local total = drive.size
    local sector_size = drive.sector_size or 512
    local read_bytes = ffi.new("DWORD[1]")
    local write_bytes = ffi.new("DWORD[1]")
    local offset = ffi.new("LARGE_INTEGER")
    local pos = 0
    local ok = true
    local err_msg = nil

    -- 4. 高性能循环
    while pos < total do
        -- 4.1 计算对齐读取量
        -- 物理磁盘读取请求必须是对齐的，即使我们只需要最后几个字节
        local remain = total - pos
        local chunk_req = math.min(BUF_SIZE, remain)
        local chunk_aligned = chunk_req
        
        if chunk_req % sector_size ~= 0 then
            chunk_aligned = math.ceil(chunk_req / sector_size) * sector_size
        end

        -- 4.2 定位磁盘指针
        offset.QuadPart = pos
        if kernel32.SetFilePointerEx(hDisk, offset, nil, 0) == 0 then
            ok = false; err_msg = util.last_error("Seek disk failed"); break
        end

        -- 4.3 读取磁盘
        if kernel32.ReadFile(hDisk, buf, chunk_aligned, read_bytes, nil) == 0 then
            ok = false; err_msg = util.last_error("Read disk failed"); break
        end

        -- 4.4 写入文件
        -- 注意：只写入有效数据 (chunk_req)，丢弃为了对齐而多读的尾部
        local bytes_valid = math.min(read_bytes[0], chunk_req)
        if bytes_valid > 0 then
            if kernel32.WriteFile(f:get(), buf, bytes_valid, write_bytes, nil) == 0 then
                ok = false; err_msg = util.last_error("Write file failed"); break
            end
        end

        pos = pos + bytes_valid
        if cb then
            if not cb(pos / total) then 
                ok = false; err_msg = "Cancelled by user"; break 
            end
        end

        if bytes_valid == 0 then break end -- EOF reached unexpectedly
    end

    -- 5. 清理
    kernel32.VirtualFree(buf, 0, 0x8000)
    f:close()

    return ok, err_msg
end

return M