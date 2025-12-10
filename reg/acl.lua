local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'

local M = {}

-- 注册表根键映射表
-- SetNamedSecurityInfo 需要特定的根名称格式
local ROOT_MAP = {
    HKLM = "MACHINE",
    HKEY_LOCAL_MACHINE = "MACHINE",
    
    HKU  = "USERS",
    HKEY_USERS = "USERS",
    
    HKCU = "CURRENT_USER",
    HKEY_CURRENT_USER = "CURRENT_USER",
    
    HKCR = "CLASSES_ROOT",
    HKEY_CLASSES_ROOT = "CLASSES_ROOT",
    
    HKCC = "CURRENT_CONFIG",
    HKEY_CURRENT_CONFIG = "CURRENT_CONFIG"
}

-- [API] 强力重置注册表键权限 (类似 PECMD HIVE -super)
-- 操作流程:
-- 1. 获取 SeTakeOwnershipPrivilege 和 SeRestorePrivilege
-- 2. 将所有者 (Owner) 修改为 Administrators 组
-- 3. 将 DACL 设为 NULL (即 Everyone Full Control，不做任何访问限制)
-- @param key_path: 注册表路径，例如 "HKLM\Software\MyKey"
-- @return: true 或 false, err_msg
function M.reset(key_path)
    if not key_path then return false, "Key path required" end
    
    -- 1. 路径标准化
    -- 将 "HKLM\Software" 转换为 "MACHINE\Software"
    local root, sub = key_path:match("^([^\\]+)\\(.*)")
    if not root then 
        -- 处理只有根键的情况 (虽然很少见需要重置根键)
        root = key_path
        sub = ""
    end
    
    local mapped_root = ROOT_MAP[root:upper()]
    if not mapped_root then
        return false, "Unknown registry root: " .. root
    end
    
    local full_path = mapped_root
    if sub ~= "" then full_path = full_path .. "\\" .. sub end
    
    -- 2. 启用特权
    -- 需要 TakeOwnership 来修改所有者
    -- 需要 Restore 来绕过某些安全检查
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    -- 3. 准备管理员 SID (S-1-5-32-544)
    -- 用于设置为新的所有者
    local admin_sid = ffi.new("PSID[1]")
    if advapi32.ConvertStringSidToSidW(util.to_wide("S-1-5-32-544"), admin_sid) == 0 then
        return false, util.last_error("ConvertStringSidToSid failed")
    end
    
    -- 4. 调用 SetNamedSecurityInfoW
    -- ObjectType = SE_REGISTRY_KEY (4)
    -- SecurityInfo = OWNER_SECURITY_INFORMATION (1) | DACL_SECURITY_INFORMATION (4) = 5
    local flags = 5
    
    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(full_path),
        4, -- SE_REGISTRY_KEY
        flags,
        admin_sid[0], -- pOwner: Administrators
        nil,          -- pGroup: Ignore
        nil,          -- pDacl:  NULL (Means Full Access for Everyone)
        nil           -- pSacl:  Ignore
    )
    
    local success = (res == 0)
    local err_msg = nil
    
    if not success then
        -- 获取错误信息
        kernel32.SetLastError(res)
        err_msg = util.last_error("SetNamedSecurityInfo failed")
    end
    
    -- 释放 SID 内存
    kernel32.LocalFree(admin_sid[0])
    
    return success, err_msg
end

return M