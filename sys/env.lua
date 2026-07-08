local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

-- [API] 获取当前进程环境变量
function M.get(name)
    local wname = util.to_wide(name)
    local size = kernel32.GetEnvironmentVariableW(wname, nil, 0)
    if size == 0 then 
        if kernel32.GetLastError() == 203 then return nil end -- ERROR_ENVVAR_NOT_FOUND
        return nil, util.last_error() 
    end
    
    local buf = ffi.new("wchar_t[?]", size)
    if kernel32.GetEnvironmentVariableW(wname, buf, size) == 0 then
        return nil, util.last_error()
    end
    return util.from_wide(buf)
end

-- [API] 设置当前进程环境变量
function M.set(name, value)
    if kernel32.SetEnvironmentVariableW(util.to_wide(name), value and util.to_wide(value) or nil) == 0 then
        return false, util.last_error()
    end
    return true
end

-- [API] 设置持久化环境变量 (注册表) 并广播
-- @param scope: "User" 或 "System"
function M.set_persistent(name, value, scope)
    scope = scope or "User"
    local key_path = (scope == "System") and "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" or "Environment"
    local root = (scope == "System") and "HKLM" or "HKCU"
    
    local k, err = reg.open_key(root, key_path)
    if not k then return false, "Registry Open Failed: " .. tostring(err) end
    
    local ok, w_err
    if value then ok, w_err = k:write(name, value, "expand_sz")
    else ok, w_err = k:delete_value(name) end
    k:close()
    
    if not ok then return false, "Registry Write Failed: " .. tostring(w_err) end
    
    local HWND_BROADCAST = ffi.cast("HWND", 0xFFFF)
    local msg_ptr = util.to_wide("Environment")
    local res_ptr = ffi.new("uintptr_t[1]") -- DWORD_PTR
    
    -- 发送广播消息，通知 Explorer 等程序更新
    if user32.SendMessageTimeoutW(HWND_BROADCAST, 0x001A, 0, ffi.cast("intptr_t", msg_ptr), 0x0002, 5000, res_ptr) == 0 then
        return false, util.last_error("Broadcast failed")
    end
    
    local _ = msg_ptr
    return true
end

-- [API] 扩展环境变量字符串 (例如 "%WINDIR%\System32" -> "C:\Windows\System32")
function M.expand(str)
    if not str then return nil end
    local wstr = util.to_wide(str)
    
    -- 第一次调用获取所需长度
    local len = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
    if len == 0 then return nil, util.last_error() end
    
    local buf = ffi.new("wchar_t[?]", len)
    if kernel32.ExpandEnvironmentStringsW(wstr, buf, len) == 0 then
        return nil, util.last_error()
    end
    
    -- from_wide 会处理末尾的 \0
    return util.from_wide(buf)
end

return M