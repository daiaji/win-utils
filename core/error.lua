local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local CP_UTF8 = 65001
local err_buf = ffi.new("wchar_t[4096]")

-- [API] 格式化指定的 Win32 错误码
function M.format(code)
    if code == 0 then return "Success" end
    -- FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS
    local len = kernel32.FormatMessageW(0x1200, nil, code, 0, err_buf, 4096, nil)
    if len > 0 then
        local req = kernel32.WideCharToMultiByte(CP_UTF8, 0, err_buf, len, nil, 0, nil, nil)
        local buf = ffi.new("char[?]", req + 1)
        kernel32.WideCharToMultiByte(CP_UTF8, 0, err_buf, len, buf, req, nil, nil)
        -- 移除末尾换行
        return ffi.string(buf, req):gsub("[\r\n]+$", "")
    end
    return string.format("Unknown Error 0x%X", code)
end

-- [API] 获取并格式化 GetLastError()
-- @param prefix: 可选，错误信息前缀
function M.last_error(prefix)
    local code = kernel32.GetLastError()
    local msg = M.format(code)
    
    if prefix then
        return string.format("%s: %s (%d)", prefix, msg, code), code
    end
    return string.format("%s (%d)", msg, code), code
end

return M