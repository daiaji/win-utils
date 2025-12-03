local ffi = require 'ffi'
local bit = require 'bit'
local wimgapi = require 'ffi.req' 'Windows.sdk.wimgapi'
local util = require 'win-utils.util'
local token = require 'win-utils.process.token'
local Handle = require 'win-utils.handle'

local M = {}

local function wim_close(h) if h then wimgapi.WIMCloseHandle(h) end end

local function enable_wim_privileges()
    token.enable_privilege("SeBackupPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    token.enable_privilege("SeSecurityPrivilege")
    token.enable_privilege("SeTakeOwnershipPrivilege")
end

function M.mount(wim_path, mount_path, index, temp_dir)
    enable_wim_privileges()
    local w_wim = util.to_wide(wim_path)
    local w_mnt = util.to_wide(mount_path)
    local acc = wimgapi.C.WIM_GENERIC_READ
    local flags = wimgapi.C.WIM_FLAG_MOUNT_READONLY
    
    if temp_dir then
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_WRITE, wimgapi.C.WIM_GENERIC_MOUNT)
        flags = wimgapi.C.WIM_FLAG_MOUNT_READWRITE
    else
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_MOUNT)
    end
    
    local hWim = wimgapi.WIMCreateFile(w_wim, acc, wimgapi.C.WIM_OPEN_EXISTING, 0, 0, nil)
    if hWim == nil then return false, "WIMCreateFile failed" end
    local safe_hWim = Handle.guard(hWim, wim_close)
    
    if temp_dir then
        if wimgapi.WIMSetTemporaryPath(hWim, util.to_wide(temp_dir)) == 0 then return false, "SetTempPath failed" end
    end
    
    local hImg = wimgapi.WIMLoadImage(hWim, index)
    if hImg == nil then return false, "LoadImage failed" end
    local safe_hImg = Handle.guard(hImg, wim_close)
    
    if wimgapi.WIMMountImageHandle(hImg, w_mnt, flags) == 0 then return false, "Mount failed: " .. util.format_error() end
    return true
end

function M.unmount(mount_path, commit)
    enable_wim_privileges()
    return wimgapi.WIMUnmountImage(util.to_wide(mount_path), nil, 0, commit and 1 or 0) ~= 0
end

function M.list_mounted()
    local len = ffi.new("DWORD[1]")
    local cnt = ffi.new("DWORD[1]")
    wimgapi.WIMGetMountedImageInfo(1, cnt, nil, 0, len)
    if len[0] == 0 then return {} end
    local buf = ffi.new("uint8_t[?]", len[0])
    if wimgapi.WIMGetMountedImageInfo(1, cnt, buf, len[0], len) == 0 then return nil end
    local res = {}
    local ptr = ffi.cast("WIM_MOUNT_INFO_LEVEL1*", buf)
    for i = 0, tonumber(cnt[0]) - 1 do
        table.insert(res, {
            wim_path = util.from_wide(ptr[i].WimPath),
            mount_path = util.from_wide(ptr[i].MountPath),
            index = tonumber(ptr[i].ImageIndex),
            rw = bit.band(tonumber(ptr[i].MountFlags), wimgapi.C.WIM_FLAG_MOUNT_READWRITE) ~= 0
        })
    end
    return res
end

return M