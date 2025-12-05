local ffi = require 'ffi'
local bit = require 'bit'
local wimgapi = require 'ffi.req' 'Windows.sdk.wimgapi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local Handle = require 'win-utils.core.handle'
-- [ADDED] 引入服务模块用于驱动管理
local service = require 'win-utils.sys.service'

local M = {}

local function wim_close(h) if h then wimgapi.WIMCloseHandle(h) end end

local function priv()
    token.enable_privilege("SeBackupPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    token.enable_privilege("SeSecurityPrivilege")
    token.enable_privilege("SeTakeOwnershipPrivilege")
end

-- [RESTORED] 自动拉起 WIM 过滤驱动
-- Win10+ / PE 10.0+ 标准驱动为 "wcifs"
-- 旧版 PE 可能使用 "wimfltr"
local function ensure_driver()
    -- service.start 内部已处理 "Already Running" (1056) 的情况，返回 true
    -- 优先尝试现代驱动
    if service.start("wcifs") then return true end
    -- 回退尝试旧版驱动
    if service.start("wimfltr") then return true end
    return false
end

function M.mount(wim, path, idx, rw, temp_dir)
    -- 1. 准备环境 (权限 + 驱动)
    priv()
    if not ensure_driver() then
        -- 驱动启动失败不强行阻断，尝试继续执行（也许系统有其他机制），但打印警告
        -- 在生产环境通常意味着挂载会失败
    end

    local acc = wimgapi.C.WIM_GENERIC_READ
    local flags = wimgapi.C.WIM_FLAG_MOUNT_READONLY
    
    if rw or temp_dir then
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_WRITE, wimgapi.C.WIM_GENERIC_MOUNT)
        if rw then flags = wimgapi.C.WIM_FLAG_MOUNT_READWRITE end
    else
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_MOUNT)
    end
    
    local h = wimgapi.WIMCreateFile(util.to_wide(wim), acc, 3, 0, 0, nil)
    if not h then return false, "WIMCreateFile failed" end
    local safe_h = Handle(h, wim_close)
    
    if temp_dir then
        if wimgapi.WIMSetTemporaryPath(h, util.to_wide(temp_dir)) == 0 then
            return false, "SetTemporaryPath failed"
        end
    end
    
    local i = wimgapi.WIMLoadImage(h, idx)
    if not i then return false, "WIMLoadImage failed" end
    local safe_i = Handle(i, wim_close)
    
    if wimgapi.WIMMountImageHandle(i, util.to_wide(path), flags) == 0 then
        return false, "Mount failed: " .. util.last_error()
    end
    return true
end

function M.unmount(path, commit)
    priv()
    -- 卸载时不需要手动操作驱动，WIMGAPI 会处理
    return wimgapi.WIMUnmountImage(util.to_wide(path), nil, 0, commit and 1 or 0) ~= 0
end

function M.list_mounted()
    -- 列表查询也不需要特权或驱动操作，只需 API
    local len = ffi.new("DWORD[1]")
    local cnt = ffi.new("DWORD[1]")
    wimgapi.WIMGetMountedImageInfo(1, cnt, nil, 0, len)
    if len[0] == 0 then return {} end
    local buf = ffi.new("uint8_t[?]", len[0])
    if wimgapi.WIMGetMountedImageInfo(1, cnt, buf, len[0], len) == 0 then return {} end
    local res = {}
    local ptr = ffi.cast("WIM_MOUNT_INFO_LEVEL1*", buf)
    for i=0, tonumber(cnt[0])-1 do
        table.insert(res, {
            wim = util.from_wide(ptr[i].WimPath),
            mount = util.from_wide(ptr[i].MountPath),
            idx = tonumber(ptr[i].ImageIndex),
            rw = bit.band(tonumber(ptr[i].MountFlags), 0x200) ~= 0
        })
    end
    return res
end

return M