local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}

-- Code Page Constants
local CP_UTF8 = 65001

-- [OPTIMIZATION] Scratch Buffer for temporary wide string conversions
-- 用于避免在短字符串转换（如路径处理、API调用）时频繁分配小块内存
local MAX_PATH_W = 32768
local scratch_buf = ffi.new("wchar_t[?]", MAX_PATH_W)
-- 注意：LuaJIT 是单线程的（Per-VM），只要不跨协程交错使用或持久化引用，
-- 在单次 FFI 调用中使用 scratch buffer 是安全的。

--- 将 Lua 字符串 (UTF-8) 转换为 Windows 宽字符 (UTF-16)
-- @param str string: Lua 字符串
-- @param use_scratch boolean: 是否使用内部缓存区（仅当结果不需要持久保存时设为 true）
-- @return cdata: wchar_t* 指针
function M.to_wide(str, use_scratch)
    if not str then return nil end
    local len = #str

    -- [OPTIMIZATION] 尝试使用 Scratch Buffer
    if use_scratch and len < (MAX_PATH_W / 4) then -- 保守估计，UTF8->UTF16 膨胀率极低
        local req_size = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, scratch_buf, MAX_PATH_W)
        if req_size > 0 then
            scratch_buf[req_size] = 0 -- Ensure Null Terminate
            return scratch_buf
        end
        -- Fallback if conversion fails or truncated (unlikely given check)
    end

    -- 获取缓冲区所需大小（字符数）。
    -- 注意：不传 -1，而是传 len，这样 Windows 不会在结果中自动计算并包含结尾的 NULL。
    -- 我们稍后通过 ffi.new 的自动归零特性来保证结尾的安全性。
    local req_size = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, nil, 0)
    if req_size == 0 then return nil end

    -- 分配内存：req_size + 1。
    -- ffi.new 返回的内存会自动归零 (Zero-initialized)。
    -- 这保证了即使原字符串没有 NULL 结尾，结果也是安全的宽字符串。
    local buf = ffi.new("wchar_t[?]", req_size + 1)

    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, len, buf, req_size)
    return buf
end

--- 将 Windows 宽字符 (UTF-16) 转换为 Lua 字符串 (UTF-8)
-- @param wstr cdata: wchar_t* 指针
-- @param wlen number|nil: 宽字符长度（不包含 NULL）。如果为 nil 或 -1，则自动扫描 NULL 结尾。
-- @return string: Lua 字符串
function M.from_wide(wstr, wlen)
    if wstr == nil then return nil end
    if ffi.cast("void*", wstr) == nil then return nil end

    local cch = wlen or -1

    -- 获取缓冲区所需字节数，传入 -1 让 API 自动扫描宽字符的结尾
    local len = kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, cch, nil, 0, nil, nil)
    if len <= 0 then return nil end

    local buf = ffi.new("char[?]", len)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wstr, cch, buf, len, nil, nil)

    if cch == -1 then
        -- len 包含结尾的 NULL 字节，ffi.string(ptr, size) 不需要包含该字节
        return ffi.string(buf, len - 1)
    else
        -- 显式长度时，返回全部转换后的字节（可能包含 NULL，取决于源数据）
        return ffi.string(buf, len)
    end
end

--- 格式化 Windows 系统错误代码为可读字符串
-- 关键修复：使用 ffi.gc 替代手动 LocalFree，防止 Heap Corruption
-- @param err_code number|nil: 错误代码，如果为 nil 则调用 GetLastError()
-- @return string: 错误描述
-- @return number: 错误代码
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

        -- [CRITICAL FIX]
        -- Windows 分配了内存 (LocalAlloc)，我们必须释放它。
        -- 以前手动调用 kernel32.LocalFree(ptr) 可能会因为 LuaJIT 的时序问题导致双重释放或访问违规。
        -- 使用 ffi.gc 绑定 LocalFree 是最安全的做法。
        local safe_ptr = ffi.gc(ptr, kernel32.LocalFree)

        msg = M.from_wide(safe_ptr)

        -- 去除 Windows 错误消息末尾常见的换行符 (CRLF)
        msg = msg:gsub("[\r\n]+$", "")

        -- safe_ptr 离开作用域后，LuaJIT 会在合适的时候调用 LocalFree
    end

    return msg, code
end

return M
