local ffi = require 'ffi'
local bit = require 'bit'
local wininet = require 'ffi.req' 'Windows.sdk.wininet'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

function M.download(url, save_path)
    -- Constants from wininet.lua (bindings)
    local hI = Handle.guard(
        wininet.InternetOpenW(util.to_wide("Lua-Win-Utils"), C.INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0),
        wininet.InternetCloseHandle
    )
    if hI == nil then return false, "InternetOpen failed" end

    -- [SAFETY] Set Timeouts (5 seconds)
    local timeout_ms = ffi.new("DWORD[1]", 5000)
    wininet.InternetSetOptionW(hI, C.INTERNET_OPTION_CONNECT_TIMEOUT, timeout_ms, ffi.sizeof("DWORD"))
    wininet.InternetSetOptionW(hI, C.INTERNET_OPTION_RECEIVE_TIMEOUT, timeout_ms, ffi.sizeof("DWORD"))

    local flags = bit.bor(C.INTERNET_FLAG_RELOAD, C.INTERNET_FLAG_NO_CACHE_WRITE)
    local hU = Handle.guard(
        wininet.InternetOpenUrlW(hI, util.to_wide(url), nil, 0, flags, 0),
        wininet.InternetCloseHandle
    )
    if hU == nil then return false, "OpenUrl failed" end

    -- Constants from kernel32.lua (bindings)
    local hF = Handle.guard(
        kernel32.CreateFileW(
            util.to_wide(save_path),
            C.GENERIC_WRITE,
            0,
            nil,
            C.CREATE_ALWAYS,
            C.FILE_ATTRIBUTE_NORMAL,
            nil
        ),
        kernel32.CloseHandle
    )

    if hF == nil then return false, "CreateFile failed" end
    -- Handle.guard handles GC cleanup automatically

    local buf_size = 8192
    local buf = ffi.new("uint8_t[?]", buf_size)
    local read = ffi.new("DWORD[1]")
    local wrote = ffi.new("DWORD[1]")
    local success = true
    local err_msg = nil

    while true do
        if wininet.InternetReadFile(hU, buf, buf_size, read) == 0 then
            success = false
            err_msg = "ReadFile failed"
            break
        end
        if read[0] == 0 then break end

        if kernel32.WriteFile(hF, buf, read[0], wrote, nil) == 0 then
            success = false
            err_msg = "WriteFile failed"
            break
        end
    end

    -- [FIX] Explicitly close file handle on success to release file lock immediately
    -- Handle.close removes the GC callback and closes the handle
    Handle.close(hF, kernel32.CloseHandle)

    -- hI and hU are left to GC (or can be closed explicitly if desired)

    if not success then return false, err_msg end
    return true
end

return M
