local ffi = require 'ffi'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local util = require 'win-utils.core.util'
local reg = require 'win-utils.reg.init'

local M = {}

local MM_ROOT = "HKLM"
local MM_KEY = [[SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management]]
local MM_VALUE = "PagingFiles"

local function open_memory_key(access)
    return reg.open_existing_key(MM_ROOT, MM_KEY, access)
end

local function parse_entry(entry)
    local path, min_mb, max_mb = tostring(entry):match("^(.-)%s+(%d+)%s+(%d+)$")
    return {
        raw = entry,
        path = path or entry,
        min_mb = min_mb and tonumber(min_mb) or nil,
        max_mb = max_mb and tonumber(max_mb) or nil,
    }
end

local function format_entry(item)
    if type(item) == "string" then return item end
    if type(item) ~= "table" then return nil end
    if not item.path then return nil end
    return string.format("%s %d %d", item.path, tonumber(item.min_mb or item.size_mb or 0), tonumber(item.max_mb or item.size_mb or 0))
end

function M.list()
    local key, err = open_memory_key()
    if not key then return nil, err end
    local values, read_err = key:read(MM_VALUE, { expand = false })
    key:close()
    if values == nil then return {}, read_err end

    local out = {}
    if type(values) == "table" then
        for _, item in ipairs(values) do out[#out + 1] = parse_entry(item) end
    elseif type(values) == "string" and values ~= "" then
        out[#out + 1] = parse_entry(values)
    end
    return out
end

function M.set(entries, opts)
    opts = opts or {}
    if type(entries) ~= "table" then return false, "entries table required" end

    local data = {}
    for _, item in ipairs(entries) do
        local entry = format_entry(item)
        if not entry then return false, "invalid pagefile entry" end
        data[#data + 1] = entry
    end

    if opts.dry_run then return { ok = true, dry_run = true, entries = data } end

    local key, err = reg.open_key(MM_ROOT, MM_KEY)
    if not key then return false, err end
    local ok, write_err = key:write(MM_VALUE, data, "multi_sz")
    key:close()
    return ok, write_err
end

function M.disable(opts)
    return M.set({}, opts)
end

function M.delete_config(path, opts)
    if not path or path == "" then return false, "path required" end
    local current, err = M.list()
    if not current then return false, err end

    local keep = {}
    local needle = path:lower()
    for _, item in ipairs(current) do
        if item.path:lower() ~= needle then keep[#keep + 1] = item end
    end
    return M.set(keep, opts)
end

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
