local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}

-- Code Page Constants
local CP_UTF8 = 65001

-- [OPTIMIZATION] Scratch Buffer for temporary wide string conversions
-- Used to avoid frequent small allocations for path conversions/API calls
local MAX_PATH_W = 32768
local scratch_buf = ffi.new("wchar_t[?]", MAX_PATH_W)
-- Note: LuaJIT is single-threaded (Per-VM), so using a static scratch buffer
-- for immediate FFI calls is safe as long as not interleaved across coroutines holding state.

--- Convert Lua string (UTF-8) to Windows Wide String (UTF-16)
-- @param str string: Lua string
-- @param use_scratch boolean: Use internal scratch buffer (result must not be persisted)
-- @return cdata: wchar_t* pointer
function M.to_wide(str, use_scratch)
    if not str then return nil end
    local len = #str

    -- [OPTIMIZATION] Try using Scratch Buffer
    if use_scratch and len < (MAX_PATH_W / 4) then 
        local req_size = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, scratch_buf, MAX_PATH_W)
        if req_size > 0 then
            scratch_buf[req_size] = 0 -- Ensure Null Terminate
            return scratch_buf
        end
    end

    -- Get required buffer size (in characters)
    local req_size = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, nil, 0)
    if req_size == 0 then return nil end

    -- Allocate memory: req_size + 1. ffi.new zero-initializes.
    local buf = ffi.new("wchar_t[?]", req_size + 1)

    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, buf, req_size)
    return buf
end

--- Convert Windows Wide String (UTF-16) to Lua String (UTF-8)
-- @param wstr cdata: wchar_t* pointer
-- @param wlen number|nil: Length (excl. null). If nil/-1, auto-scan null.
-- @return string: Lua string
function M.from_wide(wstr, wlen)
    if wstr == nil then return nil end
    if ffi.cast("void*", wstr) == nil then return nil end

    local cch = wlen or -1

    local len = kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, cch, nil, 0, nil, nil)
    if len <= 0 then return nil end

    local buf = ffi.new("char[?]", len)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, cch, buf, len, nil, nil)

    if cch == -1 then
        -- len includes null terminator, ffi.string does not need it
        return ffi.string(buf, len - 1)
    else
        return ffi.string(buf, len)
    end
end

--- Format Windows System Error Code
-- @param err_code number|nil: Error code, defaults to GetLastError()
-- @return string: Error description
-- @return number: Error code
function M.format_error(err_code)
    local code = err_code or kernel32.GetLastError()
    if code == 0 then return "Success", 0 end

    -- FORMAT_MESSAGE_ALLOCATE_BUFFER (0x100) | FORMAT_MESSAGE_FROM_SYSTEM (0x1000) | FORMAT_MESSAGE_IGNORE_INSERTS (0x200)
    local flags = 0x1300
    local buf_ptr = ffi.new("wchar_t*[1]")

    local len = kernel32.FormatMessageW(flags, nil, code, 0, ffi.cast("wchar_t*", buf_ptr), 0, nil)

    local msg = "Unknown Error (" .. tostring(code) .. ")"
    if len > 0 and buf_ptr[0] ~= nil then
        local ptr = buf_ptr[0]
        -- [CRITICAL] Use ffi.gc to bind LocalFree to prevent heap corruption
        local safe_ptr = ffi.gc(ptr, kernel32.LocalFree)
        msg = M.from_wide(safe_ptr)
        msg = msg:gsub("[\r\n]+$", "")
    end

    return msg, code
end

--- Parse a standard GUID string "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" into a GUID cdata
-- @param str string: GUID string
-- @return cdata: GUID struct (ffi.new("GUID"))
function M.guid_from_str(str)
    local guid = ffi.new("GUID")
    if not str then return guid end
    
    local d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11 = 
        str:match("{?(%x%x%x%x%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x)-(%x%x)(%x%x)-(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)}?")
        
    if d1 then
        guid.Data1 = tonumber(d1, 16)
        guid.Data2 = tonumber(d2, 16)
        guid.Data3 = tonumber(d3, 16)
        guid.Data4[0] = tonumber(d4, 16)
        guid.Data4[1] = tonumber(d5, 16)
        guid.Data4[2] = tonumber(d6, 16)
        guid.Data4[3] = tonumber(d7, 16)
        guid.Data4[4] = tonumber(d8, 16)
        guid.Data4[5] = tonumber(d9, 16)
        guid.Data4[6] = tonumber(d10, 16)
        guid.Data4[7] = tonumber(d11, 16)
    end
    return guid
end

return M