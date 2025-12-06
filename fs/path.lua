local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

function M.nt_path_to_dos(nt)
    if not nt then return nil end
    local dos_map = {} 
    local buf = ffi.new("wchar_t[512]")
    for i=65,90 do
        local drv = string.char(i)..":"
        if kernel32.QueryDosDeviceW(util.to_wide(drv), buf, 512) > 0 then
            local t = util.from_wide(buf)
            if t then dos_map[t] = drv end
        end
    end
    for k,v in pairs(dos_map) do
        if nt:find(k, 1, true) == 1 then return v .. nt:sub(#k+1) end
    end
    return nt
end

function M.abspath(path)
    local wpath = util.to_wide(path or ".")
    local len = kernel32.GetFullPathNameW(wpath, 0, nil, nil)
    if len == 0 then return nil, util.last_error() end
    
    local buf = ffi.new("wchar_t[?]", len)
    if kernel32.GetFullPathNameW(wpath, len, buf, nil) == 0 then 
        return nil, util.last_error() 
    end
    
    return util.from_wide(buf)
end

function M.basename(path)
    if not path then return nil end
    local p = path:gsub("[\\/]+$", "")
    if #p == 2 and p:sub(2,2) == ":" then return "" end
    if p == "" then return "" end
    return p:match(".*[\\/](.*)") or p
end

function M.dirname(path)
    if not path then return nil end
    local p = path:gsub("[\\/]+$", "")
    if p == "" then return "." end
    local dir = p:match("(.*)[\\/].*")
    if not dir then return p:match("^%a:$") and p or "." end
    if dir:match("^%a:$") then return dir .. "\\" end
    return dir
end

function M.join(...)
    local args = {...}
    local parts = {}
    for i, v in ipairs(args) do if v and v ~= "" then table.insert(parts, v) end end
    if #parts == 0 then return "" end
    local res = parts[1]
    for i = 2, #parts do
        local seg = parts[i]
        if seg:match("^[\\/]") or seg:match("^%a:") then res = seg 
        else res = (res:match("[\\/]$") and res or res.."\\") .. seg end
    end
    return res:gsub("/", "\\")
end

function M.splitext(path)
    if not path then return nil, nil end
    local base, ext = path:match("^(.+)(%.[^\\/]+)$")
    return (base or path), (ext or "")
end

return M