local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- 常用 CodePage 定义
M.CP_ACP   = 0      -- ANSI (系统默认区域设置)
M.CP_GBK   = 936    -- GBK / GB2312 (简体中文)
M.CP_BIG5  = 950    -- Big5 (繁体中文)
M.CP_UTF8  = 65001  -- UTF-8
M.CP_UTF16 = 1200   -- UTF-16LE (Windows 内部格式)

function M.detect_bom(data)
    data = data or ""
    if data:sub(1, 3) == "\239\187\191" then return "utf-8", 3 end
    if data:sub(1, 2) == "\255\254" then return "utf-16le", 2 end
    if data:sub(1, 2) == "\254\255" then return "utf-16be", 2 end
    return nil, 0
end

-- [API] 将任意编码字符串转换为 UTF-8 (Lua 内部通用格式)
-- @param str: 原始字符串 (Lua string)
-- @param from_cp: 源编码 CodePage (默认 CP_ACP)
-- @return: utf8_string 或 nil, err
function M.to_utf8(str, from_cp)
    if not str or str == "" then return "" end
    from_cp = from_cp or M.CP_ACP
    
    -- 1. Source (MultiByte) -> UTF-16 (WideChar)
    -- 获取所需缓冲区大小 (宽字符数)
    local len_w = kernel32.MultiByteToWideChar(from_cp, 0, str, #str, nil, 0)
    if len_w == 0 then 
        return nil, util.last_error("MultiByteToWideChar (Size) failed") 
    end
    
    local buf_w = ffi.new("wchar_t[?]", len_w)
    if kernel32.MultiByteToWideChar(from_cp, 0, str, #str, buf_w, len_w) == 0 then
        return nil, util.last_error("MultiByteToWideChar failed")
    end
    
    -- 2. UTF-16 -> UTF-8
    -- util.from_wide 内部使用的是 CP_UTF8 进行转换
    return util.from_wide(buf_w, len_w)
end

function M.to_utf8_auto(data, fallback_cp)
    local encoding, offset = M.detect_bom(data)
    data = data or ""
    if encoding == "utf-8" then return data:sub(offset + 1), encoding end
    if encoding == "utf-16le" then
        local body = data:sub(offset + 1)
        if #body % 2 ~= 0 then return nil, "Invalid UTF-16LE byte length" end
        return util.from_wide(ffi.cast("const wchar_t*", body), #body / 2), encoding
    end
    if encoding == "utf-16be" then
        local body = data:sub(offset + 1)
        if #body % 2 ~= 0 then return nil, "Invalid UTF-16BE byte length" end
        local swapped = {}
        for i = 1, #body, 2 do swapped[#swapped + 1] = body:sub(i + 1, i + 1) .. body:sub(i, i) end
        body = table.concat(swapped)
        return util.from_wide(ffi.cast("const wchar_t*", body), #body / 2), encoding
    end
    return M.to_utf8(data, fallback_cp or M.CP_UTF8)
end

-- [API] 将 UTF-8 字符串转换为指定编码 (如 GBK)
-- @param str_utf8: Lua 字符串 (必须是 UTF-8 编码)
-- @param to_cp: 目标编码 CodePage
-- @return: encoded_string 或 nil, err
function M.from_utf8(str_utf8, to_cp)
    if not str_utf8 or str_utf8 == "" then return "" end
    to_cp = to_cp or M.CP_ACP
    
    -- 1. UTF-8 -> UTF-16 (WideChar)
    local wstr = util.to_wide(str_utf8)
    if not wstr then return nil, "Invalid UTF-8 string" end
    
    -- 计算宽字符长度 (util.to_wide 返回的是带 \0 的 cdata，我们需要实际长度)
    local wlen = 0
    while wstr[wlen] ~= 0 do wlen = wlen + 1 end
    
    -- 2. UTF-16 -> Target (MultiByte)
    -- 获取所需缓冲区大小 (字节数)
    local len_a = kernel32.WideCharToMultiByte(to_cp, 0, wstr, wlen, nil, 0, nil, nil)
    if len_a == 0 then 
        return nil, util.last_error("WideCharToMultiByte (Size) failed") 
    end
    
    local buf_a = ffi.new("char[?]", len_a)
    if kernel32.WideCharToMultiByte(to_cp, 0, wstr, wlen, buf_a, len_a, nil, nil) == 0 then
        return nil, util.last_error("WideCharToMultiByte failed")
    end
    
    return ffi.string(buf_a, len_a)
end

function M.base64_encode(data)
    data = data or ""
    local out = {}
    for i = 1, #data, 3 do
        local a = data:byte(i) or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (i + 1 <= #data) and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '='
        out[#out + 1] = (i + 2 <= #data) and b64chars:sub(n % 64 + 1, n % 64 + 1) or '='
    end
    return table.concat(out)
end

function M.base64_decode(data)
    data = (data or ""):gsub("%s+", "")
    local out = {}
    for i = 1, #data, 4 do
        local chars = { data:sub(i, i), data:sub(i + 1, i + 1), data:sub(i + 2, i + 2), data:sub(i + 3, i + 3) }
        local vals = {}
        for j = 1, 4 do vals[j] = chars[j] == '=' and 0 or ((b64chars:find(chars[j], 1, true) or 1) - 1) end
        local n = vals[1] * 262144 + vals[2] * 4096 + vals[3] * 64 + vals[4]
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if chars[3] ~= '=' then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if chars[4] ~= '=' then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
end

function M.convert_file(src, dst, from_cp, to_cp)
    local f, err = io.open(src, "rb")
    if not f then return false, err end
    local data = f:read("*a")
    f:close()

    local utf8, conv_err
    if from_cp == "auto" then utf8, conv_err = M.to_utf8_auto(data)
    else utf8, conv_err = M.to_utf8(data, from_cp) end
    if not utf8 then return false, conv_err end
    local encoded
    if (to_cp or M.CP_UTF8) == M.CP_UTF8 then encoded = utf8
    else
        encoded, conv_err = M.from_utf8(utf8, to_cp)
        if not encoded then return false, conv_err end
    end

    local out, open_err = io.open(dst, "wb")
    if not out then return false, open_err end
    local ok, write_err = out:write(encoded)
    out:close()
    if not ok then return false, write_err end
    return true
end

return M
