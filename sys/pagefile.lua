local ffi = require 'ffi'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local util = require 'win-utils.core.util'

local M = {}

-- 创建/修改系统页面文件
-- @param path: 完整 DOS 路径 (例如 "C:\pagefile.sys")
-- @param min_mb: 初始大小 (MB)
-- @param max_mb: 最大大小 (MB)
function M.create(path, min_mb, max_mb)
    -- 1. 权限检查
    if not token.enable_privilege("SeCreatePagefilePrivilege") then
        return false, "SeCreatePagefilePrivilege required (Run as Admin)"
    end

    -- 2. 路径转换 (DOS -> NT)
    local nt_path = native.dos_path_to_nt_path(path)
    if not nt_path then return false, "Invalid path format" end
    
    local us_path, anchor = native.to_unicode_string(nt_path)
    
    -- 3. 大小转换 (MB -> Bytes)
    local min_sz = ffi.new("LARGE_INTEGER")
    local max_sz = ffi.new("LARGE_INTEGER")
    
    -- LuaJIT double (53-bit int) 足够处理 PB 级内存，乘法安全
    min_sz.QuadPart = min_mb * 1024 * 1024
    max_sz.QuadPart = max_mb * 1024 * 1024
    
    -- 4. 调用 Native API
    -- Priority 0 = System Managed
    local status = ntext.NtCreatePagingFile(us_path, min_sz, max_sz, 0)
    
    -- 保持 UnicodeString Buffer 存活
    local _ = anchor
    
    if status < 0 then 
        return false, string.format("NtCreatePagingFile failed: 0x%X", tonumber(status)) 
    end
    
    return true
end

return M