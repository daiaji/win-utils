local ffi = require 'ffi'
local bit = require 'bit'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'

local M = {}

-- 常量定义
local SE_FILE_OBJECT = 1
local OWNER_SECURITY_INFORMATION = 1
local DACL_SECURITY_INFORMATION = 4
local GENERIC_ALL = 0x10000000
local SUB_CONTAINERS_AND_OBJECTS_INHERIT = 3
local GRANT_ACCESS = 1
local TRUSTEE_IS_NAME = 1
local TRUSTEE_IS_UNKNOWN = 0

-- [API] 强力重置权限 (Take Ownership + Clear DACL)
-- 使得 Everyone 拥有完全控制权，类似 PECMD 的强力删除前置操作
-- @param path: 文件或目录路径
-- @return: boolean success, string err_msg
function M.reset(path)
    if not path then return false, "Path required" end

    -- 1. 启用特权
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")

    -- 2. 准备管理员 SID (S-1-5-32-544)
    local admin_sid = ffi.new("PSID[1]")
    if advapi32.ConvertStringSidToSidW(util.to_wide("S-1-5-32-544"), admin_sid) == 0 then
        return false, util.last_error("ConvertStringSidToSid failed")
    end

    -- 3. 调用 SetNamedSecurityInfoW
    -- 将所有者设为 Admin，DACL 设为 NULL (意味着 Everyone Full Access)
    local flags = bit.bor(OWNER_SECURITY_INFORMATION, DACL_SECURITY_INFORMATION)

    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        SE_FILE_OBJECT,
        flags,
        admin_sid[0], -- pOwner
        nil,          -- pGroup
        nil,          -- pDacl (NULL = Full Access)
        nil           -- pSacl
    )

    local success = (res == 0)
    local err_msg = nil

    if not success then
        kernel32.SetLastError(res)
        err_msg = util.last_error("SetNamedSecurityInfo failed")
    end
    
    kernel32.LocalFree(admin_sid[0])
    return success, err_msg
end

-- [API] 授予指定用户完全控制权 (保留现有权限)
-- @param path: 文件路径
-- @param account: 用户名 (默认 "Everyone")
-- @return: boolean success, string err_msg
function M.grant(path, account)
    if not path then return false, "Path required" end
    account = account or "Everyone"

    -- 1. 获取现有 DACL
    -- 我们需要读取现有的 DACL 以便追加新权限，而不是覆盖
    local ppDacl = ffi.new("void*[1]")
    local ppSD = ffi.new("void*[1]")

    local get_res = advapi32.GetNamedSecurityInfoW(
        util.to_wide(path),
        SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        nil, nil, ppDacl, nil, ppSD
    )

    -- 如果获取失败，ppDacl[0] 可能为 NULL，SetEntriesInAclW 会创建一个新的 ACL

    -- 2. 构建 EXPLICIT_ACCESS 结构
    local ea = ffi.new("EXPLICIT_ACCESS_W")
    local wAccount = util.to_wide(account)

    ea.grfAccessPermissions = GENERIC_ALL
    ea.grfAccessMode = GRANT_ACCESS
    ea.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT

    ea.Trustee.TrusteeForm = TRUSTEE_IS_NAME
    ea.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN
    ea.Trustee.ptstrName = wAccount

    -- 3. 合并 ACL (创建新的 ACL)
    local ppNewDacl = ffi.new("void*[1]")
    local res = advapi32.SetEntriesInAclW(1, ea, ppDacl[0], ppNewDacl)

    if res ~= 0 then
        if ppSD[0] ~= nil then kernel32.LocalFree(ppSD[0]) end
        kernel32.SetLastError(res)
        return false, util.last_error("SetEntriesInAcl failed")
    end

    -- 4. 应用新 ACL
    token.enable_privilege("SeSecurityPrivilege")
    token.enable_privilege("SeRestorePrivilege")

    local set_res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        nil, nil, ppNewDacl[0], nil
    )

    -- 5. 清理内存
    if ppNewDacl[0] ~= nil then kernel32.LocalFree(ppNewDacl[0]) end
    if ppSD[0] ~= nil then kernel32.LocalFree(ppSD[0]) end

    if set_res ~= 0 then
        kernel32.SetLastError(set_res)
        return false, util.last_error("SetNamedSecurityInfo failed")
    end

    return true
end

return M
