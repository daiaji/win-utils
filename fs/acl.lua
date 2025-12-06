local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'

local M = {}

function M.reset(path)
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    local flags = 4 -- DACL_SECURITY_INFORMATION
    
    local res = advapi32.SetNamedSecurityInfoW(
        util.to_wide(path),
        1, -- SE_FILE_OBJECT
        flags,
        nil, nil, nil, nil
    )
    
    if res ~= 0 then return false, util.last_error("SetNamedSecurityInfo failed") end
    return true
end

return M