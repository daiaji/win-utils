local ffi = require 'ffi'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local util = require 'win-utils.util'
local token = require 'win-utils.process.token'
local native = require 'win-utils.native'

local M = {}

-- 创建/设置系统页面文件
-- @param path: 完整路径 (例如 "C:\pagefile.sys")
-- @param min_mb: 初始大小 (MB)
-- @param max_mb: 最大大小 (MB)
-- @return: boolean success, string error
function M.create(path, min_mb, max_mb)
    -- 1. 必须启用 SeCreatePagefilePrivilege 权限
    if not token.enable_privilege("SeCreatePagefilePrivilege") then
        return false, "Failed to enable SeCreatePagefilePrivilege (Administrator required)"
    end

    -- 2. 转换路径为 NT 格式 (\??\C:\pagefile.sys)
    local nt_path_str = native.dos_path_to_nt_path(path)
    if not nt_path_str then return false, "Invalid path format" end
    
    local us_path, anchor = native.to_unicode_string(nt_path_str)
    
    -- 3. 准备大小参数 (Bytes)
    local min_size = ffi.new("LARGE_INTEGER")
    local max_size = ffi.new("LARGE_INTEGER")
    
    -- 注意: LuaJIT numbers are doubles, limit is 2^53. MB conversion is safe.
    min_size.QuadPart = min_mb * 1024 * 1024
    max_size.QuadPart = max_mb * 1024 * 1024
    
    -- 4. 调用 Native API
    -- Priority 0 = 系统自动管理优先级
    local status = ntext.NtCreatePagingFile(us_path, min_size, max_size, 0)
    
    -- 保持 unicode_string buffer 存活直到调用结束
    local _ = anchor
    
    if status < 0 then
        return false, string.format("NtCreatePagingFile failed: 0x%08X", status)
    end
    
    return true
end

return M