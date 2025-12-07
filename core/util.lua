local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local error_mod = require 'win-utils.core.error'

local M = {}
local CP_UTF8 = 65001

-- [Universal Error Helpers] ---------------------------------------------------

-- 检查 BOOL 返回值，失败时返回 false, err_msg
function M.check_bool(res, context)
    if res ~= 0 and res ~= false then return true end
    local msg, code = error_mod.last_error(context)
    return false, msg, code
end

-- 检查 HANDLE 返回值，失败时返回 nil, err_msg
-- 兼容 0 和 -1 (INVALID_HANDLE_VALUE) 两种失败模式
function M.check_handle(h, context)
    local val = ffi.cast("intptr_t", h)
    if val == 0 or val == -1 then
        local msg, code = error_mod.last_error(context)
        return nil, msg, code
    end
    return h
end

-- [String Conversion] ---------------------------------------------------------

function M.to_wide(str)
    if not str then return nil end
    local len = #str
    local req = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, nil, 0)
    if req == 0 then return nil end 
    
    local buf = ffi.new("wchar_t[?]", req + 1)
    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, buf, req)
    buf[req] = 0
    return buf
end

function M.from_wide(wstr, len)
    if wstr == nil or ffi.cast("void*", wstr) == nil then return nil end
    len = len or -1
    local req = kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, nil, 0, nil, nil)
    if req == 0 then return nil end
    local buf = ffi.new("char[?]", req)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, buf, req, nil, nil)
    if len == -1 then return ffi.string(buf, req - 1) end
    return ffi.string(buf, req)
end

-- [GUID Helpers] --------------------------------------------------------------

function M.guid_to_str(g)
    local d4 = ""
    for i=0,7 do d4=d4..string.format("%02X", g.Data4[i]) end
    return string.format("{%08X-%04X-%04X-%s-%s}", 
        g.Data1, g.Data2, g.Data3, d4:sub(1,4), d4:sub(5))
end

function M.guid_from_str(s)
    local g = ffi.new("GUID")
    -- [Defensive] 如果传入 nil，返回全零 GUID，避免崩溃
    if not s then return g end
    
    local d1, d2, d3, d4_1, d4_2 = s:match("{?(%x+)-(%x+)-(%x+)-(%x+)-(%x+)}?")
    if d1 then
        g.Data1 = tonumber(d1, 16)
        g.Data2 = tonumber(d2, 16)
        g.Data3 = tonumber(d3, 16)
        local d4s = d4_1 .. d4_2
        for i=0,7 do g.Data4[i] = tonumber(d4s:sub(i*2+1, i*2+2), 16) end
    end
    return g
end

-- [IOCTL Helper] --------------------------------------------------------------

function M.ioctl(handle, code, in_obj, in_size, out_type, out_size)
    local in_ptr, in_bytes = nil, 0
    if in_obj then
        if type(in_obj) == "cdata" then in_ptr = in_obj; in_bytes = in_size or ffi.sizeof(in_obj)
        elseif type(in_obj) == "string" then in_ptr = ffi.cast("void*", in_obj); in_bytes = #in_obj end
    end
    
    local out_buf, out_bytes = nil, 0
    if out_type then
        if type(out_type) == "string" then out_buf = ffi.new(out_type); out_bytes = ffi.sizeof(out_type)
        elseif type(out_type) == "cdata" then out_buf = out_type; out_bytes = out_size or ffi.sizeof(out_buf) end
    end
    
    local bytes_ret = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(handle, code, in_ptr, in_bytes, out_buf, out_bytes, bytes_ret, nil)
    
    if res == 0 then 
        local msg, err_code = error_mod.last_error()
        return nil, msg, err_code
    end
    
    return (out_buf or true), bytes_ret[0]
end

function M.last_error(p) return error_mod.last_error(p) end

-- [Path Helpers] --------------------------------------------------------------

function M.split_path(path)
    local parts = {}
    for part in path:gmatch("[^\\/]+") do
        table.insert(parts, part)
    end
    return parts
end

function M.normalize_path(path)
    if not path then return nil end
    local res = path:gsub("/", "\\")
    local is_unc = res:match("^\\\\")
    res = res:gsub("\\+", "\\")
    if is_unc then 
        if res:sub(1,1) == "\\" then res = "\\" .. res else res = "\\\\" .. res end
    end
    res = res:gsub("\\+$", "")
    if #res == 2 and res:sub(2,2) == ":" then res = res .. "\\" end
    return res
end

return M