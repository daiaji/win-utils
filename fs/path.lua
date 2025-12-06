local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- [Legacy] NT Path -> DOS Path Conversion
local dos_map = nil
function M.nt_path_to_dos(nt)
    if not dos_map then
        dos_map = {}
        local buf = ffi.new("wchar_t[512]")
        for i=65,90 do
            local drv = string.char(i)..":"
            if kernel32.QueryDosDeviceW(util.to_wide(drv), buf, 512) > 0 then
                local t = util.from_wide(buf)
                if t then dos_map[t] = drv end
            end
        end
    end
    if not nt then return nil end
    for k,v in pairs(dos_map) do
        if nt:find(k, 1, true) == 1 then return v .. nt:sub(#k+1) end
    end
    return nt
end

-- ========================================================================
-- Coreutils: Path Manipulation
-- ========================================================================

-- [abspath] Get Absolute Path (Resolve relative . and ..)
function M.abspath(path)
    local wpath = util.to_wide(path or ".")
    -- 第一次调用获取所需长度
    local len = kernel32.GetFullPathNameW(wpath, 0, nil, nil)
    if len == 0 then return nil end
    
    local buf = ffi.new("wchar_t[?]", len)
    if kernel32.GetFullPathNameW(wpath, len, buf, nil) == 0 then return nil end
    
    return util.from_wide(buf)
end

-- [basename] Get Filename component
function M.basename(path)
    if not path then return nil end
    -- 移除尾部斜杠 (除了根目录)
    local p = path:gsub("[\\/]+$", "")
    
    -- 处理根目录情况 (C:\)
    if #p == 2 and p:sub(2,2) == ":" then return "" end
    if p == "" then return "" end
    
    -- 匹配最后一个分隔符后的内容
    local name = p:match(".*[\\/](.*)")
    return name or p
end

-- [dirname] Get Directory component
function M.dirname(path)
    if not path then return nil end
    local p = path:gsub("[\\/]+$", "")
    
    if p == "" then return "." end
    
    -- 匹配最后一个分隔符前的内容
    local dir = p:match("(.*)[\\/].*")
    
    if not dir then
        -- 处理 "C:" -> "C:" (当前目录?) 或 "file" -> "."
        if p:match("^%a:$") then return p end
        return "." 
    end
    
    -- 处理根目录 "C:\" 变 "C:" 的问题，恢复为 "C:\"
    if dir:match("^%a:$") then return dir .. "\\" end
    
    return dir
end

-- [join] Join path segments safely
function M.join(...)
    local args = {...}
    local parts = {}
    for i, v in ipairs(args) do
        if v and v ~= "" then table.insert(parts, v) end
    end
    
    if #parts == 0 then return "" end
    
    local res = parts[1]
    for i = 2, #parts do
        local seg = parts[i]
        local sep = "\\"
        
        -- 如果片段是绝对路径 (以 / \ 或 C: 开头)，则重置结果
        if seg:match("^[\\/]") or seg:match("^%a:") then
            res = seg 
        else
            -- 补充分隔符
            if not res:match("[\\/]$") then
                res = res .. sep
            end
            res = res .. seg
        end
    end
    
    -- 规范化反斜杠
    return res:gsub("/", "\\")
end

-- [splitext] Split extension
-- returns: base, ext (including dot)
function M.splitext(path)
    if not path then return nil, nil end
    -- 匹配最后一个点，且点不在路径分隔符之前
    local base, ext = path:match("^(.+)(%.[^\\/]+)$")
    if base then 
        return base, ext 
    end
    return path, ""
end

return M