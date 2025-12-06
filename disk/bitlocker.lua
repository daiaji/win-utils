local ffi = require 'ffi'
local native = require 'win-utils.core.native'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 检查指定盘符或路径是否被 BitLocker 加密
-- 原理：直接读取卷引导记录 (VBR) 的 OEM ID 字段 (Offset 0x03, Length 8)
-- 返回: "Locked", "None", 或 nil + error
function M.get_status(path)
    -- 规范化路径 (e.g. "C:" -> "\\.\C:")
    local vol_path = path
    if vol_path:match("^[A-Za-z]:$") then 
        vol_path = "\\\\.\\" .. vol_path 
    elseif vol_path:match("^[A-Za-z]:\\$") then 
        vol_path = "\\\\.\\" .. vol_path:sub(1, 2) 
    end

    -- 打开卷 (需要读取权限，允许共享读写)
    local h, err = native.open_file(vol_path, "r", true) 
    if not h then return nil, "Open failed: " .. tostring(err) end

    -- 读取第一个扇区 (512字节)
    local buf = ffi.new("uint8_t[512]")
    local bytes_read = ffi.new("DWORD[1]")
    
    local res = kernel32.ReadFile(h:get(), buf, 512, bytes_read, nil)
    h:close()

    if res == 0 or bytes_read[0] < 512 then
        return nil, util.last_error("Read VBR failed")
    end

    -- 检查 NTFS/FAT32/ExFAT 偏移 0x03 (OEM ID)
    -- BitLocker 修改此字段为 "-FVE-FS-"
    local oem_id = ffi.string(buf + 3, 8)
    
    if oem_id == "-FVE-FS-" then
        return "Locked"
    end

    return "None"
end

-- [API] 检测卷是否处于“已解锁”状态
-- 返回: true (已解锁/无加密), false (未解锁/无法访问), 或 nil + error
function M.is_unlocked(path)
    local status, err = M.get_status(path)
    
    -- 如果状态获取失败，透传错误，而不是假定已解锁
    if not status then return nil, err end
    
    -- 未加密视为已解锁
    if status ~= "Locked" then return true end 
    
    -- 如果被标记为 Locked，尝试列出根目录文件
    -- 只需要能成功打开根目录句柄即可证明已解锁 (利用 native 模块)
    local root_path = path
    if not root_path:match("\\$") then root_path = root_path .. "\\" end
    
    local h = native.open_file(root_path, "r") 
    if h then
        h:close()
        return true
    end
    
    return false
end

return M