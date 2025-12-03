local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local CP_UTF8 = 65001
local scratch_buf = ffi.new("wchar_t[32768]") 

function M.to_wide(str, use_scratch)
    if not str then return nil end
    local len = #str
    -- print("[UTIL] to_wide len=" .. len) -- Extremely verbose
    if use_scratch and len < 8192 then 
        local req = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, scratch_buf, 32768)
        if req > 0 then scratch_buf[req] = 0; return scratch_buf end
    end
    
    -- Ensure explicit 0 termination length calculation
    local req = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, nil, 0)
    if req == 0 then return nil end -- Fail safe
    
    local buf = ffi.new("wchar_t[?]", req + 1)
    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, buf, req)
    buf[req] = 0 -- Null terminate explicitly
    return buf
end

function M.from_wide(wstr, len)
    if wstr == nil or ffi.cast("void*", wstr) == nil then return nil end
    len = len or -1
    local req = kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, nil, 0, nil, nil)
    if req == 0 then return nil end
    
    local buf = ffi.new("char[?]", req)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, buf, req, nil, nil)
    -- If len was -1, req includes the null terminator. If not, string might be raw.
    -- ffi.string handles length correctly.
    if len == -1 then return ffi.string(buf, req - 1) end
    return ffi.string(buf, req)
end

function M.format_error(code)
    code = code or kernel32.GetLastError()
    if code == 0 then return "Success", 0 end
    local buf_ptr = ffi.new("wchar_t*[1]")
    local len = kernel32.FormatMessageW(0x1300, nil, code, 0, ffi.cast("wchar_t*", buf_ptr), 0, nil)
    if len > 0 then
        local msg = M.from_wide(buf_ptr[0])
        kernel32.LocalFree(buf_ptr[0])
        return msg:gsub("[\r\n]+$", ""), code
    end
    return "Error " .. code, code
end

function M.guid_from_str(str)
    local guid = ffi.new("GUID")
    if not str then return guid end
    local d = { str:match("{?(%x+)-(%x+)-(%x+)-(%x%x)(%x%x)-(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)}?") }
    if #d == 11 then
        guid.Data1 = tonumber(d[1], 16); guid.Data2 = tonumber(d[2], 16); guid.Data3 = tonumber(d[3], 16)
        guid.Data4[0] = tonumber(d[4], 16); guid.Data4[1] = tonumber(d[5], 16)
        for i=0,5 do guid.Data4[i+2] = tonumber(d[i+6], 16) end
    end
    return guid
end

function M.ioctl(handle, code, in_obj, in_size, out_type, out_size)
    local out_buf, out_bytes = nil, 0
    if out_type then
        if type(out_type) == "string" then
            out_buf = ffi.new(out_type)
            out_bytes = ffi.sizeof(out_type)
        else
            out_buf = out_type
            out_bytes = out_size or ffi.sizeof(out_buf)
        end
    end
    local in_bytes = in_size or (in_obj and ffi.sizeof(in_obj) or 0)
    local bytes_ret = ffi.new("DWORD[1]")
    local res = kernel32.DeviceIoControl(handle, code, in_obj, in_bytes, out_buf, out_bytes, bytes_ret, nil)
    if res == 0 then return nil, M.format_error() end
    return (out_buf or true), bytes_ret[0]
end

return M