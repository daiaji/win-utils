local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local defs = require 'win-utils.disk.defs'

local M = {}

-- 自动挂载管理
function M.set_automount(enable)
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return false end
    local state = ffi.new("int[1]", enable and 1 or 0)
    local res = util.ioctl(h, defs.IOCTL.MOUNTMGR_SET_AUTO_MOUNT, state, 4)
    kernel32.CloseHandle(h)
    return res ~= nil
end

function M.get_automount()
    local h = kernel32.CreateFileW(util.to_wide("\\\\.\\MountPointManager"), 0, 3, nil, 3, 0, nil)
    if h == ffi.cast("HANDLE", -1) then return nil end
    local state = util.ioctl(h, defs.IOCTL.MOUNTMGR_QUERY_AUTO_MOUNT, nil, 0, "int")
    kernel32.CloseHandle(h)
    return state and (state[0] == 1)
end

-- [FIX] 恢复强制挂载 (DefineDosDeviceW)
-- 这对于将物理路径 \Device\HarddiskVolumeX 映射为盘符至关重要
function M.force_mount(letter, target)
    -- DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM
    local flags = 0x9 
    local t = target
    
    -- 处理 NT 路径格式，DefineDosDeviceW 的 RAW 模式需要原生 NT 路径
    -- 移除 Lua 侧的转义，确保只有一层 \??\
    if t:match("^%\\%?%?%\\") then 
        t = t:sub(5) 
    end
    
    if not t:match("^%\\") then 
        t = "\\??\\" .. t 
    elseif not t:match("^%\\%?%?%\\") then
        t = "\\??\\" .. t:sub(2) -- 假设是 \Device\...
    end
    
    -- 实际上 DefineDosDeviceW(DDD_RAW_TARGET_PATH) 需要的是完整的 NT 对象路径
    -- 例如 \Device\HarddiskVolume1
    -- 如果 target 已经是 NT 路径，则直接使用
    
    return kernel32.DefineDosDeviceW(flags, util.to_wide(letter), util.to_wide(target)) ~= 0
end

function M.force_unmount(letter)
    -- DDD_REMOVE_DEFINITION | DDD_NO_BROADCAST_SYSTEM
    local flags = 0xA
    return kernel32.DefineDosDeviceW(flags, util.to_wide(letter), nil) ~= 0
end

return M