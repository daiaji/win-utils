local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- [which] Locate executable in PATH
-- Emulates standard `where` or `which` behavior
function M.which(name)
    local buf_len = 1024
    local buf = ffi.new("wchar_t[?]", buf_len)
    local file_part = ffi.new("LPWSTR[1]")
    
    -- SearchPathW(path, filename, ext, buflen, buf, filepart)
    -- path=NULL means use system search order
    -- ext=NULL means look for exact match or append default ext
    
    local res = kernel32.SearchPathW(nil, util.to_wide(name), nil, buf_len, buf, file_part)
    if res == 0 then return nil end
    
    return util.from_wide(buf)
end

return M