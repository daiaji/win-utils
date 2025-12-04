local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'

-- [FIX] Explicitly load Advapi32 for SetNamedSecurityInfoW
local advapi32 = ffi.load("advapi32")

ffi.cdef[[
    DWORD SetNamedSecurityInfoW(
        LPWSTR pObjectName,
        int ObjectType,
        DWORD SecurityInfo,
        PSID psidOwner,
        PSID psidGroup,
        PSECURITY_DESCRIPTOR pDacl,
        PSECURITY_DESCRIPTOR pSacl
    );
]]

local M = {}

-- 暴力重置权限：将 DACL 设为 NULL (Everyone Full Control)
-- 自动获取所有权和恢复权限
function M.reset(path)
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    -- SE_FILE_OBJECT = 1
    -- OWNER_SECURITY_INFORMATION (1) | DACL_SECURITY_INFORMATION (4)
    local flags = 5
    
    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        1, -- SE_FILE_OBJECT
        flags,
        nil, -- Owner (nil keeps current, or implied self by SeTakeOwnership)
        nil, -- Group
        nil, -- NULL DACL (Implicitly allow all)
        nil  -- SACL
    )
    
    return res == 0
end

return M