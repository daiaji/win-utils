local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local CP_UTF8 = 65001
local err_buf = ffi.new("wchar_t[4096]")

function M.last_error()
    local code = kernel32.GetLastError()
    if code == 0 then return "Success", 0 end
    local len = kernel32.FormatMessageW(0x1200, nil, code, 0, err_buf, 4096, nil)
    if len > 0 then
        local req = kernel32.WideCharToMultiByte(CP_UTF8, 0, err_buf, len, nil, 0, nil, nil)
        local buf = ffi.new("char[?]", req)
        kernel32.WideCharToMultiByte(CP_UTF8, 0, err_buf, len, buf, req, nil, nil)
        return ffi.string(buf, req):gsub("[\r\n]+$", ""), code
    end
    return "Error " .. code, code
end

return M