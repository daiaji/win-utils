local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local native = require 'win-utils.native'
local registry = require 'win-utils.registry'
local token = require 'win-utils.process.token'
local util = require 'win-utils.util'
local newdev = require 'ffi.req' 'Windows.sdk.newdev'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'

local M = {}
local C = ffi.C

-- 1. Kernel Driver Loading (NtLoadDriver)
-- Loads a legacy kernel driver by creating a service entry manually
function M.load(path, name)
    if not path or not name then return false, "Invalid arguments" end

    local key_path = "SYSTEM\\CurrentControlSet\\Services\\" .. name
    local key = registry.open_key("HKLM", key_path)
    
    -- 如果服务键不存在，自动创建
    if not key then
        local hKey = ffi.new("HKEY[1]")
        -- HKLM = 0x80000002, KEY_ALL_ACCESS = 0xF003F
        local res = advapi32.RegCreateKeyExW(ffi.cast("HKEY", 0x80000002), util.to_wide(key_path), 0, nil, 0, 0xF003F, nil, hKey, nil)
        if res ~= 0 then return false, "Could not create service registry key: " .. res end
        
        -- 使用 Handle 包装以复用 Registry 模块逻辑 (这里手动关闭句柄即可，因为只是临时写入)
        advapi32.RegCloseKey(hKey[0])
        key = registry.open_key("HKLM", key_path)
    end
    
    if not key then return false, "Failed to open created key" end
    
    -- 写入服务配置
    -- Type 1 = SERVICE_KERNEL_DRIVER
    -- Start 3 = SERVICE_DEMAND_START
    -- ErrorControl 1 = SERVICE_ERROR_NORMAL
    local nt_image_path = native.dos_path_to_nt_path(path)
    key:write("ImagePath", nt_image_path, "string")
    key:write("Type", 1, "dword")
    key:write("Start", 3, "dword")
    key:write("ErrorControl", 1, "dword")
    key:close()
    
    -- 启用加载驱动权限
    if not token.enable_privilege("SeLoadDriverPrivilege") then
        return false, "Failed to enable SeLoadDriverPrivilege"
    end
    
    local registry_path = "\\Registry\\Machine\\" .. key_path
    local oa, anchor = native.init_object_attributes(registry_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtLoadDriver(oa)
    local _ = anchor -- Keep alive
    
    if status == 0xC000010E then return true, "Already loaded" end -- STATUS_IMAGE_ALREADY_LOADED
    
    if status < 0 then
        return false, string.format("NtLoadDriver failed: 0x%X", status)
    end
    
    return true
end

function M.unload(name)
    if not name then return false, "Invalid service name" end

    if not token.enable_privilege("SeLoadDriverPrivilege") then
        return false, "Failed to enable SeLoadDriverPrivilege"
    end
    
    local registry_path = "\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\" .. name
    local oa, anchor = native.init_object_attributes(registry_path, nil, C.OBJ_CASE_INSENSITIVE)
    
    local status = ntdll.NtUnloadDriver(oa)
    local _ = anchor
    
    -- STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034) is acceptable (already unloaded/not exist)
    if status < 0 and status ~= 0xC0000034 then
        return false, string.format("NtUnloadDriver failed: 0x%X", status)
    end
    
    return true
end

-- 2. PnP Driver Installation (INF)
function M.install(inf, force)
    local reboot = ffi.new("BOOL[1]")
    -- DiInstallDriverW does not support flags in current SDK binding, pass 0
    local res = newdev.DiInstallDriverW(nil, util.to_wide(inf), 0, reboot)
    if res == 0 then return false, util.format_error() end
    return true, reboot[0] ~= 0
end

function M.update_device(hwid, inf, force)
    local reboot = ffi.new("BOOL[1]")
    local flags = force and 1 or 0 -- INSTALLFLAG_FORCE
    local res = newdev.UpdateDriverForPlugAndPlayDevicesW(nil, util.to_wide(hwid), util.to_wide(inf), flags, reboot)
    if res == 0 then return false, util.format_error() end
    return true, reboot[0] ~= 0
end

function M.add_to_store(inf)
    -- MediaType=1 (SPOST_PATH), CopyStyle=4 (SP_COPY_NOOVERWRITE)
    -- Params: Source, Location, MediaType, Style, DestName, DestSize, ReqSize, Comp
    local res = setupapi.SetupCopyOEMInfW(util.to_wide(inf), nil, 1, 4, nil, 0, nil, nil)
    if res == 0 then return false, util.format_error() end
    return true
end

return M