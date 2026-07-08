local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local env = require 'win-utils.sys.env'

local M = {}

function M.which(name)
    local buf_len = 1024
    local buf = ffi.new("wchar_t[?]", buf_len)
    local file_part = ffi.new("LPWSTR[1]")
    
    if kernel32.SearchPathW(nil, util.to_wide(name), nil, buf_len, buf, file_part) == 0 then
        return nil -- Not found is not an error in 'which' context usually, but nil is correct
    end
    
    return util.from_wide(buf)
end

function M.temp_dir()
    local len = kernel32.GetTempPathW(0, nil)
    if len == 0 then return nil, util.last_error("GetTempPathW failed") end
    local buf = ffi.new("wchar_t[?]", len + 1)
    if kernel32.GetTempPathW(len + 1, buf) == 0 then return nil, util.last_error("GetTempPathW failed") end
    return util.from_wide(buf)
end

function M.split_path(value)
    value = value or env.get("PATH") or ""
    local out = {}
    for part in tostring(value):gmatch("[^;]+") do
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

function M.join_path(parts)
    return table.concat(parts or {}, ";")
end

function M.contains_path(dir, value)
    if not dir or dir == "" then return false end
    local needle = dir:gsub("[\\/]+$", ""):lower()
    for _, part in ipairs(M.split_path(value)) do
        if part:gsub("[\\/]+$", ""):lower() == needle then return true end
    end
    return false
end

function M.add_path(dir, opts)
    opts = opts or {}
    if not dir or dir == "" then return false, "dir required" end
    local current = opts.value or env.get("PATH") or ""
    if M.contains_path(dir, current) then return current end
    local parts = M.split_path(current)
    if opts.prepend then table.insert(parts, 1, dir) else parts[#parts + 1] = dir end
    local value = M.join_path(parts)
    if opts.dry_run or opts.value ~= nil then return value end
    return env.set("PATH", value)
end

function M.remove_path(dir, opts)
    opts = opts or {}
    if not dir or dir == "" then return false, "dir required" end
    local needle = dir:gsub("[\\/]+$", ""):lower()
    local out = {}
    for _, part in ipairs(M.split_path(opts.value or env.get("PATH") or "")) do
        if part:gsub("[\\/]+$", ""):lower() ~= needle then out[#out + 1] = part end
    end
    local value = M.join_path(out)
    if opts.dry_run or opts.value ~= nil then return value end
    return env.set("PATH", value)
end

return M
