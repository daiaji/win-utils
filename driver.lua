local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local native = require 'win-utils.native'
local registry = require 'win-utils.registry'
local token = require 'win-utils.process.token'
local util = require 'win-utils.util'
local newdev = require 'ffi.req' 'Windows.sdk.newdev'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'

local M = {}
local C = ffi.C

-------------------------------------------------------------------------------
-- 1. Kernel Driver Loading (NtLoadDriver) - For .sys files without INF
-------------------------------------------------------------------------------

-- Load a legacy kernel driver using Native API (Bypass SCM)
-- This is typically used for loading specialized kernel utilities like process monitors.
-- @param driver_path: DOS path to the .sys file
-- @param service_name: Name of the service registry key to create
function M.load(driver_path, service_name)
    if not service_name or not driver_path then return false, "Invalid args" end
    
    -- 1. Setup Registry in HKLM\SYSTEM\CurrentControlSet\Services
    local key_path = "SYSTEM\\CurrentControlSet\\Services\\" .. service_name
    local key = registry.open_key("HKLM", key_path)
    if not key then
        -- Create if not exists
        local advapi = require('ffi.req')('Windows.sdk.advapi32')
        local hKey = ffi.new("HKEY[1]")
        -- HKLM = 0x80000002, KEY_ALL_ACCESS = 0xF003F
        local hRoot = ffi.cast("HKEY", 0x80000002) 
        if advapi.RegCreateKeyExW(hRoot, util.to_wide(key_path), 0, nil, 0, 0xF003F, nil, hKey, nil) == 0 then
            advapi.RegCloseKey(hKey[0])
            key = registry.open_key("HKLM", key_path)
        end
    end
    
    if not key then return false, "Could not create registry key" end
    
    -- Convert path to NT path for ImagePath (\??\C:\...)
    local nt_path = native.dos_path_to_nt_path(driver_path)
    
    key:write("ImagePath", nt_path, "string")
    key:write("Type", 1, "dword") -- SERVICE_KERNEL_DRIVER
    key:write("Start", 3, "dword") -- SERVICE_DEMAND_START
    key:write("ErrorControl", 1, "dword") -- SERVICE_ERROR_NORMAL
    key:close()
    
    -- 2. Enable SeLoadDriverPrivilege
    if not token.enable_privilege("SeLoadDriverPrivilege") then
        return false, "Failed to enable SeLoadDriverPrivilege"
    end
    
    -- 3. Call NtLoadDriver
    local registry_path = "\\Registry\\Machine\\" .. key_path
    -- [Guideline #4] Anchor objects to prevent GC
    local oa, anchor = native.init_object_attributes(registry_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtLoadDriver(oa)
    
    -- Keep anchor alive
    local _ = anchor
    
    if status < 0 then
        -- STATUS_IMAGE_ALREADY_LOADED = 0xC000010E
        if status == 0xC000010E then return true, "Already loaded" end
        return false, string.format("NtLoadDriver failed: 0x%X", status)
    end
    
    return true
end

-- Unload a kernel driver using Native API
function M.unload(service_name)
    if not service_name then return false, "Invalid args" end
    
    if not token.enable_privilege("SeLoadDriverPrivilege") then
        return false, "Failed to enable SeLoadDriverPrivilege"
    end
    
    local key_path = "SYSTEM\\CurrentControlSet\\Services\\" .. service_name
    local registry_path = "\\Registry\\Machine\\" .. key_path
    
    local oa, anchor = native.init_object_attributes(registry_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtUnloadDriver(oa)
    local _ = anchor
    
    if status < 0 then
        -- STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034
        if status == 0xC0000034 then return false, "Driver not found" end
        return false, string.format("NtUnloadDriver failed: 0x%X", status)
    end
    
    return true
end

-------------------------------------------------------------------------------
-- 2. PnP Driver Installation (INF based) - Modern Approach
-------------------------------------------------------------------------------

-- Standard install (DiInstallDriver)
-- Equivalent to: Right-click INF -> Install.
-- This creates a driver node and installs it on matching devices if present.
-- @param inf_path: Full path to the .inf file
-- @param force: (Unused in DiInstallDriver, kept for signature compatibility)
-- @return: boolean success, string message (e.g. "Reboot required")
function M.install(inf_path, force)
    if not inf_path then return false, "Invalid path" end
    
    local wpath = util.to_wide(inf_path)
    local need_reboot = ffi.new("BOOL[1]")
    local flags = 0
    
    -- Note: DiInstallDriver doesn't use INSTALLFLAG_FORCE like UpdateDriver does.
    local res = newdev.DiInstallDriverW(nil, wpath, flags, need_reboot)
    
    if res == 0 then
        return false, util.format_error()
    end
    
    if need_reboot[0] ~= 0 then
        return true, "Reboot required"
    end
    
    return true, "Success"
end

-- Force install for a specific Hardware ID (UpdateDriverForPlugAndPlayDevices)
-- Reference: Snappy Driver Installer (install64.c)
-- Used when you have determined (via matching logic) that a specific INF is best for a specific Device.
-- @param hwid: Hardware ID string (e.g. "PCI\VEN_8086&DEV_1234...")
-- @param inf_path: Full path to .inf file
-- @param force: boolean, if true applies INSTALLFLAG_FORCE (downgrade protection override)
function M.update_device(hwid, inf_path, force)
    if not hwid or not inf_path then return false, "Invalid args" end
    
    local w_hwid = util.to_wide(hwid)
    local w_inf = util.to_wide(inf_path)
    local need_reboot = ffi.new("BOOL[1]")
    
    local flags = 0
    if force then
        -- [Guideline #10] Access constants via C, NOT newdev.C
        flags = bit.bor(flags, C.INSTALLFLAG_FORCE)
    end
    
    -- HWND is NULL (headless operation)
    local res = newdev.UpdateDriverForPlugAndPlayDevicesW(nil, w_hwid, w_inf, flags, need_reboot)
    
    if res == 0 then
        return false, util.format_error()
    end
    
    if need_reboot[0] ~= 0 then
        return true, "Reboot required"
    end
    
    return true, "Success"
end

-- Pre-install driver to Driver Store (SetupCopyOEMInf)
-- Useful for PE initialization: Pre-load drivers so PnP finds them on rescan/plug-in.
-- @param inf_path: Full path to .inf file
function M.add_to_store(inf_path)
    if not inf_path then return false, "Invalid path" end
    
    local w_inf = util.to_wide(inf_path)
    
    -- [CRITICAL FIX] 
    -- SPOST_PATH (1) is passed as MediaType (Param 3).
    -- SP_COPY_NOOVERWRITE (4) is passed as CopyStyle (Param 4).
    -- DO NOT OR them together! SPOST_PATH=1 is same value as SP_COPY_DELETESOURCE=1.
    -- If we use bit.bor(C.SPOST_PATH, ...), we accidentally set SP_COPY_DELETESOURCE!
    
    local media_type = C.SPOST_PATH
    local copy_style = C.SP_COPY_NOOVERWRITE
    
    -- SetupCopyOEMInfW(Source, Location, Type, Style, DestName, DestSize, ReqSize, Comp)
    -- We pass NULL for optional outputs as we just want to stage it.
    local res = setupapi.SetupCopyOEMInfW(
        w_inf,
        nil,        -- OEMSourceMediaLocation
        media_type, -- SPOST_PATH
        copy_style, -- CopyStyle
        nil,        -- DestinationInfFileName
        0,          -- DestinationInfFileNameSize
        nil,        -- RequiredSize
        nil         -- DestinationInfFileNameComponent
    )
    
    if res == 0 then
        return false, util.format_error()
    end
    
    return true
end

return M