local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

function M.which(name)
    local buf_len = 1024
    local buf = ffi.new("wchar_t[?]", buf_len)
    local file_part = ffi.new("LPWSTR[1]")
    
    if kernel32.SearchPathW(nil, util.to_wide(name), nil, buf_len, buf, file_part) == 0 then
        return nil -- Not found is not an error in 'which' context usually, but nil is correct
    end
    
    return util.from_wide(buf)
end

return M