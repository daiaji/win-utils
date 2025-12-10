local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local error_mod = require 'win-utils.core.error'
local fbwflib = require 'ffi.req' 'Windows.sdk.fbwflib'

local M = {}

-- [Internal] Error Checker (0 is Success)
local function check(res)
    if res == 0 then return true end
    return false, error_mod.format(res), res
end

-- [API] 检查 FBWF 是否可用
function M.is_available()
    return pcall(function() return fbwflib.FbwfEnableFilter end)
end

-- [API] 启用 FBWF (全局)
function M.enable()
    return check(fbwflib.FbwfEnableFilter())
end

-- [API] 禁用 FBWF (全局)
function M.disable()
    return check(fbwflib.FbwfDisableFilter())
end

-- [API] 设置写保护阈值 (内存缓存大小)
-- @param mb: 大小 (MB)
function M.set_threshold(mb)
    local bytes = math.floor(mb * 1024 * 1024)
    return check(fbwflib.FbwfSetThreshold(bytes))
end

-- [API] 获取当前阈值 (MB)
function M.get_threshold()
    local ptr = ffi.new("unsigned long[1]")
    local res = fbwflib.FbwfGetThreshold(ptr)
    if res ~= 0 then return nil, error_mod.format(res) end
    
    return tonumber(ptr[0]) / (1024 * 1024)
end

-- [API] 保护指定卷
-- @param vol: 盘符，如 "X:" (不需要反斜杠)
function M.protect(vol)
    -- 规范化盘符
    local v = vol
    if v:match("^%a:$") then v = v else v = v:sub(1, 2) end
    
    return check(fbwflib.FbwfProtectVolume(util.to_wide(v), 0))
end

-- [API] 取消保护指定卷
function M.unprotect(vol)
    local v = vol
    if v:match("^%a:$") then v = v else v = v:sub(1, 2) end
    
    return check(fbwflib.FbwfUnprotectVolume(util.to_wide(v)))
end

-- [API] 添加排除项 (即允许写入并穿透到磁盘的文件/目录)
-- @param vol: 盘符 "X:"
-- @param path: 相对路径 (不带盘符)，如 "Windows\System32\Config"
function M.add_exclusion(vol, path)
    -- FBWF 要求路径不以 \ 开头
    local clean_path = path:gsub("^[\\/]", "")
    local clean_vol = vol:sub(1, 2)
    
    return check(fbwflib.FbwfAddExclusion(util.to_wide(clean_vol), util.to_wide(clean_path)))
end

-- [API] 移除排除项
function M.remove_exclusion(vol, path)
    local clean_path = path:gsub("^[\\/]", "")
    local clean_vol = vol:sub(1, 2)
    
    return check(fbwflib.FbwfRemoveExclusion(util.to_wide(clean_vol), util.to_wide(clean_path)))
end

-- [API] 提交文件更改到物理磁盘
-- @param path: 完整路径 "X:\File.txt"
function M.commit(path)
    return check(fbwflib.FbwfCommitFile(util.to_wide(path)))
end

-- [API] 恢复文件 (丢弃缓存中的修改)
function M.restore(path)
    return check(fbwflib.FbwfRestoreFile(util.to_wide(path)))
end

-- [API] 获取缓存使用详情
function M.get_cache_info()
    local detail = ffi.new("FBWF_CACHE_DETAIL")
    local res = fbwflib.FbwfGetCacheDetail(detail)
    
    if res ~= 0 then return nil, error_mod.format(res) end
    
    return {
        used_bytes = tonumber(detail.cacheSize),
        open_files = tonumber(detail.openFiles),
        flags = tonumber(detail.flags)
    }
end

return M