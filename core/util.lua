local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local error_mod = require 'win-utils.core.error'

local M = {}
local CP_UTF8 = 65001

-- [Modern LuaJIT]
function M.to_wide(str)
    if not str then return nil end
    local len = #str
    local req = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, nil, 0)
    if req == 0 then return nil end 
    
    -- VLA allocation is fast in LuaJIT, essentially equivalent to stack alloc in C
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

-- ... [guid functions unchanged] ...

-- [Modern LuaJIT] Simplified ioctl flow
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
    
    -- [Lua 5.2 Style] return multiple values natively without extra table packaging if redundant
    return (out_buf or true), bytes_ret[0]
end

function M.last_error() return error_mod.last_error() end

return M