local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'

local M = {}

-- 暴力重置权限：将 DACL 设为 NULL (Everyone Full Control)
-- 自动获取所有权和恢复权限
function M.reset(path)
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    -- [FIX] Only DACL (4). Do not request OWNER (1) if passing NULL owner.
    local flags = 4 
    
    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        1, -- SE_FILE_OBJECT
        flags,
        nil, -- Owner (NULL keeps current)
        nil, -- Group
        nil, -- NULL DACL (Everyone Full Control)
        nil  -- SACL
    )
    
    return res == 0
end

return M