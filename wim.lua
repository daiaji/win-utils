local ffi = require 'ffi'
local bit = require 'bit'
local wimgapi = require 'ffi.req' 'Windows.sdk.wimgapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local token = require 'win-utils.process.token'
local service = require 'win-utils.service'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

-- WIMGAPI Handle Guard
local function wim_close(h)
    if h then wimgapi.WIMCloseHandle(h) end
end

-- Helper: Ensure WIM drivers are running
-- Windows 10+ uses wcifs, older uses wimfltr
local function check_drivers()
    -- Try modern first
    local wcifs_status = service.query("wcifs")
    if wcifs_status then
        if wcifs_status.status ~= 4 then -- SERVICE_RUNNING = 4
            service.start("wcifs")
        end
        return true
    end
    
    -- Try legacy
    local wimfltr_status = service.query("wimfltr")
    if wimfltr_status then
        if wimfltr_status.status ~= 4 then
            service.start("wimfltr")
        end
        return true
    end
    
    return false, "No WIM filter driver found (wcifs/wimfltr)"
end

-- Prepare privileges required for WIM mounting
local function enable_wim_privileges()
    token.enable_privilege("SeBackupPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    token.enable_privilege("SeSecurityPrivilege")
    -- SeTakeOwnershipPrivilege might also be needed in some cases
    token.enable_privilege("SeTakeOwnershipPrivilege")
end

--- Mount a WIM image
-- @param wim_path string: Path to .wim file
-- @param mount_path string: Target directory (must exist and be empty)
-- @param index number: Image index (1-based)
-- @param temp_dir string|nil: Temporary directory for RW mount. If nil, mount as Read-Only.
-- @return boolean, string: Success, Error message
function M.mount(wim_path, mount_path, index, temp_dir)
    enable_wim_privileges()
    
    local ok, err = check_drivers()
    if not ok then return false, err end

    local w_wim_path = util.to_wide(wim_path)
    local w_mount_path = util.to_wide(mount_path)
    
    -- 1. Create/Open WIM Handle
    local access = wimgapi.C.WIM_GENERIC_READ
    local mount_flags = wimgapi.C.WIM_FLAG_MOUNT_READONLY
    local open_flags = 0 -- WIM_FLAG_VERIFY?
    
    if temp_dir then
        access = bit.bor(access, wimgapi.C.WIM_GENERIC_WRITE, wimgapi.C.WIM_GENERIC_MOUNT)
        mount_flags = wimgapi.C.WIM_FLAG_MOUNT_READWRITE
    else
        access = bit.bor(access, wimgapi.C.WIM_GENERIC_MOUNT)
    end
    
    local hWim = wimgapi.WIMCreateFile(
        w_wim_path,
        access,
        wimgapi.C.WIM_OPEN_EXISTING,
        open_flags,
        0, -- CompressionType (0 for open)
        nil
    )
    
    if hWim == nil then 
        return false, "WIMCreateFile failed: " .. util.format_error() 
    end
    -- Use manual handle management inside function scope for finer control, 
    -- or wrap with guard for safety if error occurs.
    local safe_hWim = Handle.guard(hWim, wim_close)
    
    -- 2. Set Temp Path (if RW)
    if temp_dir then
        local w_temp = util.to_wide(temp_dir)
        if wimgapi.WIMSetTemporaryPath(hWim, w_temp) == 0 then
            return false, "WIMSetTemporaryPath failed: " .. util.format_error()
        end
        -- w_temp anchor kept alive by local scope
    end
    
    -- 3. Load Image
    local hImage = wimgapi.WIMLoadImage(hWim, index)
    if hImage == nil then
        return false, "WIMLoadImage failed: " .. util.format_error()
    end
    local safe_hImage = Handle.guard(hImage, wim_close)
    
    -- 4. Mount
    if wimgapi.WIMMountImageHandle(hImage, w_mount_path, mount_flags) == 0 then
        return false, "WIMMountImageHandle failed: " .. util.format_error()
    end
    
    -- Success. 
    -- Note: We must CloseHandle(hImage) and CloseHandle(hWim) after mounting?
    -- MSDN: "The WIMMountImageHandle function maps the content... You can close the image and WIM handles after the mount operation completes."
    -- So the guards will close them when function returns, which is correct.
    
    return true
end

--- Unmount a WIM image
-- @param mount_path string: The directory where the image is mounted
-- @param commit boolean: Save changes?
-- @return boolean, string: Success, Error message
function M.unmount(mount_path, commit)
    enable_wim_privileges()
    
    local w_mount_path = util.to_wide(mount_path)
    
    -- WIMUnmountImage(MountPath, WimPath, Index, Commit)
    -- WimPath/Index are optional/unused usually when unmounting by path.
    if wimgapi.WIMUnmountImage(w_mount_path, nil, 0, commit and 1 or 0) == 0 then
        return false, util.format_error()
    end
    
    return true
end

--- List mounted images
-- @return table: List of { wim_path, mount_path, index, rw }
function M.list_mounted()
    -- Get Size first
    local cbMountInfo = ffi.new("DWORD[1]")
    local pdwReturnLength = ffi.new("DWORD[1]")
    local pdwImageCount = ffi.new("DWORD[1]")
    
    -- InfoLevel 1 returns WIM_MOUNT_INFO_LEVEL1
    wimgapi.WIMGetMountedImageInfo(1, pdwImageCount, nil, 0, pdwReturnLength)
    
    if pdwReturnLength[0] == 0 then return {} end
    
    local buf = ffi.new("uint8_t[?]", pdwReturnLength[0])
    
    if wimgapi.WIMGetMountedImageInfo(1, pdwImageCount, buf, pdwReturnLength[0], pdwReturnLength) == 0 then
        return nil, util.format_error()
    end
    
    local results = {}
    local ptr = ffi.cast("WIM_MOUNT_INFO_LEVEL1*", buf)
    
    for i = 0, tonumber(pdwImageCount[0]) - 1 do
        local info = ptr[i]
        local flags = tonumber(info.MountFlags)
        table.insert(results, {
            wim_path = util.from_wide(info.WimPath),
            mount_path = util.from_wide(info.MountPath),
            index = tonumber(info.ImageIndex),
            rw = bit.band(flags, wimgapi.C.WIM_FLAG_MOUNT_READWRITE) ~= 0
        })
    end
    
    return results
end

return M