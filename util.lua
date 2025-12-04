local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local CP_UTF8 = 65001

-- [OPTIMIZATION] Shared scratch buffer for path conversions (up to 64KB chars)
-- Removes overhead of ffi.new() for every single API call.
-- Not thread-safe, but LuaJIT is single-threaded.
local SCRATCH_SIZE = 32768
local scratch_buf = ffi.new("wchar_t[?]", SCRATCH_SIZE)

function M.to_wide(str)
    if not str then return nil end
    local len = #str
    
    -- Fast path for common short strings
    if len < (SCRATCH_SIZE - 1) then
        local req = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, scratch_buf, SCRATCH_SIZE)
        if req > 0 then
            scratch_buf[req] = 0 -- Null terminate
            return scratch_buf
        end
    end
    
    -- Fallback for huge strings
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
    
    -- Guess size if unknown to optimize buffer allocation
    -- (Actually, WideCharToMultiByte handles buffer size calc, so we just use 0 if dynamic)
    
    local req = kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, nil, 0, nil, nil)
    if req == 0 then return nil end
    
    local buf = ffi.new("char[?]", req)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, len, buf, req, nil, nil)
    
    -- If len was -1, req includes the null terminator, strict Lua strings don't need it at end
    if len == -1 then return ffi.string(buf, req - 1) end
    return ffi.string(buf, req)
end

function M.format_error(code)
    code = code or kernel32.GetLastError()
    if code == 0 then return "Success", 0 end
    
    -- Reuse scratch buffer for error messages to avoid allocation
    local FLAGS = 0x1200 -- FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS
    local len = kernel32.FormatMessageW(FLAGS, nil, code, 0, scratch_buf, SCRATCH_SIZE, nil)
    
    if len > 0 then
        -- Convert in-place from scratch buffer
        local msg = M.from_wide(scratch_buf, len)
        return msg:gsub("[\r\n]+$", ""), code
    end
    return "System Error " .. code, code
end

function M.guid_from_str(str)
    local guid = ffi.new("GUID")
    if not str then return guid end
    -- Optimized parse without creating table
    local d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11 = 
        str:match("{?(%x+)-(%x+)-(%x+)-(%x%x)(%x%x)-(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)}?")
    
    if d1 then
        guid.Data1 = tonumber(d1, 16)
        guid.Data2 = tonumber(d2, 16)
        guid.Data3 = tonumber(d3, 16)
        guid.Data4[0] = tonumber(d4, 16); guid.Data4[1] = tonumber(d5, 16)
        guid.Data4[2] = tonumber(d6, 16); guid.Data4[3] = tonumber(d7, 16)
        guid.Data4[4] = tonumber(d8, 16); guid.Data4[5] = tonumber(d9, 16)
        guid.Data4[6] = tonumber(d10, 16); guid.Data4[7] = tonumber(d11, 16)
    end
    return guid
end

function M.ioctl(handle, code, in_obj, in_size, out_type, out_size)
    local out_buf, out_bytes = nil, 0
    
    -- Smart Output Buffer Allocation
    if out_type then
        if type(out_type) == "string" then
            out_buf = ffi.new(out_type)
            out_bytes = ffi.sizeof(out_type)
        elseif type(out_type) == "cdata" then
            out_buf = out_type
            out_bytes = out_size or ffi.sizeof(out_buf)
        end
    end
    
    local in_bytes = in_size or (in_obj and ffi.sizeof(in_obj) or 0)
    local bytes_ret = ffi.new("DWORD[1]")
    
    local res = kernel32.DeviceIoControl(
        handle, code, 
        in_obj, in_bytes, 
        out_buf, out_bytes, 
        bytes_ret, nil
    )
    
    if res == 0 then return nil, M.format_error() end
    return (out_buf or true), bytes_ret[0]
end

return M