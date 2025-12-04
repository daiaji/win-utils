local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local error_mod = require 'win-utils.core.error'

local M = {}
local CP_UTF8 = 65001

function M.to_wide(str)
    if not str then return nil end
    local len = #str
    -- 始终分配新缓冲区，防止冲突
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

function M.guid_from_str(str)
    local guid = ffi.new("GUID")
    if not str then return guid end
    local d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11 = 
        str:match("{?(%x+)-(%x+)-(%x+)-(%x%x)(%x%x)-(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)}?")
    if d1 then
        guid.Data1 = tonumber(d1, 16); guid.Data2 = tonumber(d2, 16); guid.Data3 = tonumber(d3, 16)
        guid.Data4[0] = tonumber(d4, 16); guid.Data4[1] = tonumber(d5, 16)
        guid.Data4[2] = tonumber(d6, 16); guid.Data4[3] = tonumber(d7, 16)
        guid.Data4[4] = tonumber(d8, 16); guid.Data4[5] = tonumber(d9, 16)
        guid.Data4[6] = tonumber(d10, 16); guid.Data4[7] = tonumber(d11, 16)
    end
    return guid
end

function M.guid_to_str(g)
    return string.format("{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        g.Data1, g.Data2, g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7])
end

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

function M.last_error() return error_mod.last_error() end

return M