local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

-- [get] Get Environment Variable
function M.get(name)
    local wname = util.to_wide(name)
    local size = kernel32.GetEnvironmentVariableW(wname, nil, 0)
    if size == 0 then return nil end
    
    local buf = ffi.new("wchar_t[?]", size)
    kernel32.GetEnvironmentVariableW(wname, buf, size)
    return util.from_wide(buf)
end

-- [set] Set Process Environment Variable
function M.set(name, value)
    return kernel32.SetEnvironmentVariableW(util.to_wide(name), value and util.to_wide(value) or nil) ~= 0
end

-- [set_persistent] Set User/System Variable + Broadcast
-- scope: "User" (Default) or "System" (Requires Admin)
function M.set_persistent(name, value, scope)
    scope = scope or "User"
    local key_path
    
    if scope == "System" then
        key_path = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"
    else
        key_path = "Environment" -- HKCU
    end
    
    -- 1. Write Registry
    local root = (scope == "System") and "HKLM" or "HKCU"
    local k = reg.open_key(root, key_path)
    if not k then return false, "Failed to open registry key" end
    
    local ok
    if value then
        ok = k:write(name, value, "expand_sz") -- Use REG_EXPAND_SZ usually
    else
        ok = k:delete_value(name)
    end
    k:close()
    
    if not ok then return false, "Registry write failed" end
    
    -- 2. Broadcast WM_SETTINGCHANGE
    -- HWND_BROADCAST = 0xFFFF
    -- WM_SETTINGCHANGE = 0x001A
    -- SMTO_ABORTIFHUNG = 0x0002
    
    local HWND_BROADCAST = ffi.cast("HWND", 0xFFFF)
    local msg_ptr = util.to_wide("Environment")
    local res_ptr = ffi.new("DWORD[1]")
    
    -- SendMessageTimeoutW(HWND, Msg, wParam, lParam, flags, timeout, result)
    user32.SendMessageTimeoutW(
        HWND_BROADCAST, 
        0x001A, 
        0, 
        ffi.cast("LPARAM", msg_ptr), 
        0x0002, 
        5000, 
        res_ptr
    )
    
    -- 锚定字符串防止 GC
    local _ = msg_ptr
    
    return true
end

return M