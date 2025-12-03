local ffi = require 'ffi'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local native = require 'win-utils.native'
local token = require 'win-utils.process.token'

local M = {}

function M.create(path, min_mb, max_mb)
    if not token.enable_privilege("SeCreatePagefilePrivilege") then return false, "No privilege" end
    local us, anchor = native.to_unicode_string(native.dos_path_to_nt_path(path))
    local min, max = ffi.new("LARGE_INTEGER"), ffi.new("LARGE_INTEGER")
    min.QuadPart = min_mb * 1048576
    max.QuadPart = max_mb * 1048576
    
    local status = ntext.NtCreatePagingFile(us, min, max, 0)
    local _ = anchor
    return status >= 0, string.format("0x%X", status)
end

return M