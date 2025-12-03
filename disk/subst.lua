local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- 辅助：刷新资源管理器，使新盘符立即生效
local function broadcast_change()
    -- HWND_BROADCAST = 0xFFFF
    -- WM_SETTINGCHANGE = 0x001A
    -- 发送消息通知环境变更
    local w_env = util.to_wide("Environment")
    -- 使用 PostMessageW 异步通知，避免阻塞
    user32.PostMessageW(ffi.cast("HWND", 0xFFFF), 0x001A, 0, ffi.cast("LPARAM", w_env))
end

-- 挂载目录为虚拟盘符 (SUBJ / subst)
-- @param drive: 盘符字符串，例如 "B:"
-- @param path: 目标目录路径，例如 "C:\\Temp"
-- @return: boolean success, string error
function M.mount(drive, path)
    if not drive or #drive ~= 2 or drive:sub(2,2) ~= ":" then
        return false, "Invalid drive letter format (Expected X:)"
    end
    if not path then return false, "Invalid path" end

    -- DefineDosDeviceW
    -- 0 = 创建新的映射 (非 RAW 模式，系统会自动添加 \??\ 前缀)
    local flags = 0
    
    local w_drive = util.to_wide(drive)
    local w_path = util.to_wide(path)
    
    if kernel32.DefineDosDeviceW(flags, w_drive, w_path) == 0 then
        return false, util.format_error()
    end
    
    broadcast_change()
    return true
end

-- 卸载虚拟盘符
-- @param drive: 盘符字符串，例如 "B:"
function M.unmount(drive)
    if not drive or #drive ~= 2 then return false, "Invalid drive letter" end
    
    local flags = C.DDD_REMOVE_DEFINITION
    local w_drive = util.to_wide(drive)
    
    -- target_path 传 nil 表示移除该设备名的所有映射 (通常只有一个)
    -- 如果需要精确移除，需传入原路径并加 DDD_EXACT_MATCH_ON_REMOVE
    if kernel32.DefineDosDeviceW(flags, w_drive, nil) == 0 then
        return false, util.format_error()
    end
    
    broadcast_change()
    return true
end

-- 查询盘符映射目标
-- @param drive: 盘符字符串，例如 "B:"
-- @return: string target_path 或 nil
function M.query(drive)
    local w_drive = util.to_wide(drive)
    local buf_size = 1024
    local buf = ffi.new("wchar_t[?]", buf_size)
    
    local res = kernel32.QueryDosDeviceW(w_drive, buf, buf_size)
    if res == 0 then return nil end
    
    local target = util.from_wide(buf)
    
    -- 虚拟盘符映射通常以 NT 路径前缀开头 "\??\"
    -- 例如: "\??\C:\Windows\Temp"
    if target:sub(1, 4) == "\\??\\" then
        return target:sub(5)
    end
    
    return target
end

return M