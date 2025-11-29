local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local INVALID_HANDLE = ffi.cast("HANDLE", -1)

-- RAII 包装器
-- @param handle: 原始句柄
-- @param closer: 关闭函数 (默认为 kernel32.CloseHandle)
-- @return: 附加了 __gc 的句柄 (cdata)，如果句柄无效则返回 nil
function M.guard(handle, closer)
    if handle == nil or handle == INVALID_HANDLE then return nil end
    closer = closer or kernel32.CloseHandle

    -- 使用 ffi.gc 绑定关闭函数
    return ffi.gc(handle, function(h)
        -- 再次检查防止 Double Free (尽管 ffi.gc 通常只调一次，但防御性编程更好)
        if h ~= INVALID_HANDLE then
            closer(h)
        end
    end)
end

-- 显式关闭并解除 GC 锚定
-- @param handle: 由 guard 返回的句柄
-- @param closer: 关闭函数 (必须与 guard 时一致)
function M.close(handle, closer)
    if handle == nil then return end
    closer = closer or kernel32.CloseHandle

    -- 解除 GC 回调，避免 Double Free
    ffi.gc(handle, nil)

    if handle ~= INVALID_HANDLE then
        closer(handle)
    end
end

return M
