local ffi = require 'ffi'
local bit = require 'bit'
local wimgapi = require 'ffi.req' 'Windows.sdk.wimgapi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local Handle = require 'win-utils.core.handle'
local service = require 'win-utils.sys.service'

local M = {}

local function wim_close(h) if h then wimgapi.WIMCloseHandle(h) end end

local function priv()
    token.enable_privilege("SeBackupPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    token.enable_privilege("SeSecurityPrivilege")
    token.enable_privilege("SeTakeOwnershipPrivilege")
end

local function ensure_driver()
    if service.start("wcifs") then return true end
    if service.start("wimfltr") then return true end
    return false
end

function M.mount(wim, path, idx, rw, temp_dir)
    priv()
    ensure_driver()

    local acc = wimgapi.C.WIM_GENERIC_READ
    local flags = wimgapi.C.WIM_FLAG_MOUNT_READONLY
    
    if rw or temp_dir then
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_WRITE, wimgapi.C.WIM_GENERIC_MOUNT)
        if rw then flags = wimgapi.C.WIM_FLAG_MOUNT_READWRITE end
    else
        acc = bit.bor(acc, wimgapi.C.WIM_GENERIC_MOUNT)
    end
    
    local h = wimgapi.WIMCreateFile(util.to_wide(wim), acc, 3, 0, 0, nil)
    if not h then return false, util.last_error("WIMCreateFile failed") end
    local safe_h = Handle(h, wim_close)
    
    if temp_dir then
        if wimgapi.WIMSetTemporaryPath(h, util.to_wide(temp_dir)) == 0 then
            return false, util.last_error("SetTemporaryPath failed")
        end
    end
    
    local i = wimgapi.WIMLoadImage(h, idx)
    if not i then return false, util.last_error("WIMLoadImage failed") end
    local safe_i = Handle(i, wim_close)
    
    if wimgapi.WIMMountImageHandle(i, util.to_wide(path), flags) == 0 then
        return false, util.last_error("Mount failed")
    end
    return true
end

function M.unmount(path, commit)
    priv()
    if wimgapi.WIMUnmountImage(util.to_wide(path), nil, 0, commit and 1 or 0) == 0 then
        return false, util.last_error("Unmount failed")
    end
    return true
end

function M.list_mounted()
    local len = ffi.new("DWORD[1]")
    local cnt = ffi.new("DWORD[1]")
    
    wimgapi.WIMGetMountedImageInfo(1, cnt, nil, 0, len)
    if len[0] == 0 then return {} end
    
    local buf = ffi.new("uint8_t[?]", len[0])
    if wimgapi.WIMGetMountedImageInfo(1, cnt, buf, len[0], len) == 0 then 
        return nil, util.last_error("GetMountedImageInfo failed") 
    end
    
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