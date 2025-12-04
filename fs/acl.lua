local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'

local M = {}

-- [Security] 暴力重置文件权限 (Take Ownership + Reset DACL)
function M.reset(path)
    -- 需要提权
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    -- DACL_SECURITY_INFORMATION (4)
    local flags = 4 
    
    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        1, -- SE_FILE_OBJECT
        flags,
        nil, -- Owner (保持不变)
        nil, -- Group
        nil, -- DACL = NULL (意味着 Everyone Full Control)
        nil  -- SACL
    )
    
    return res == 0
end

return M