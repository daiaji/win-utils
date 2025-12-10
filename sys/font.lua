local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local gdi32 = require 'ffi.req' 'Windows.sdk.gdi32'
local util = require 'win-utils.core.util'

local M = {}

-- 常量定义
local FR_PRIVATE  = 0x10
local FR_NOT_ENUM = 0x20
local WM_FONTCHANGE = 0x001D
local HWND_BROADCAST = ffi.cast("HWND", 0xFFFF)

-- [API] 注册字体
-- @param path: 字体文件路径
-- @param opts: 
--    opts.private (bool): 仅当前进程可见，不广播 (默认 false)
--    opts.not_enum (bool): 不枚举 (默认 false)
--    opts.notify (bool): 是否广播字体变更消息 (默认 true，除非 private=true)
-- @return: boolean success, number added_count_or_error_code
function M.add(path, opts)
    opts = opts or {}
    local flags = 0
    if opts.private then flags = bit.bor(flags, FR_PRIVATE) end
    if opts.not_enum then flags = bit.bor(flags, FR_NOT_ENUM) end
    
    local wpath = util.to_wide(path)
    -- AddFontResourceExW 返回添加的字体数量，0 表示失败
    local added = gdi32.AddFontResourceExW(wpath, flags, nil)
    
    if added == 0 then
        return false, util.last_error("AddFontResourceEx failed")
    end
    
    -- 如果不是私有字体，且未显式禁止通知，则广播消息
    if opts.notify ~= false and not opts.private then
        -- 使用 SendMessageTimeout 防止因顶层窗口无响应导致卡死
        local res = ffi.new("uintptr_t[1]")
        -- SMTO_ABORTIFHUNG (0x0002), Timeout 1000ms
        user32.SendMessageTimeoutW(HWND_BROADCAST, WM_FONTCHANGE, 0, 0, 0x0002, 1000, res)
    end
    
    return true, added
end

-- [API] 移除字体
function M.remove(path, opts)
    opts = opts or {}
    local flags = 0
    if opts.private then flags = bit.bor(flags, FR_PRIVATE) end
    if opts.not_enum then flags = bit.bor(flags, FR_NOT_ENUM) end
    
    local wpath = util.to_wide(path)
    if gdi32.RemoveFontResourceExW(wpath, flags, nil) == 0 then
        return false, util.last_error("RemoveFontResourceEx failed")
    end
    
    if opts.notify ~= false and not opts.private then
        local res = ffi.new("uintptr_t[1]")
        user32.SendMessageTimeoutW(HWND_BROADCAST, WM_FONTCHANGE, 0, 0, 0x0002, 1000, res)
    end
    return true
end

return M