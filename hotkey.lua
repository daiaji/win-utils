local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'

-- 防止回调被 GC 的锚点表
local anchors = {}

local M = {}

-- 将 Lua 函数转换为 C 回调指针
-- 注意：这里假设宿主会正确 dispatch 消息，Lua 只是注册方
-- 如果需要在 Lua 端处理 WndProc，逻辑会极其复杂，通常 pesh_core 是通过 id 映射来回调的
-- 这里我们还原原 pesh_ffi_core 的逻辑：注册 ID -> 宿主收到消息 -> 调用 Lua dispatch

function M.register(modifiers, key, callback)
    -- 生成唯一 ID (范围 1 ~ 0xBFFF)
    local id = 1
    while anchors[id] do id = id + 1 end
    if id > 0xBFFF then return nil, "Too many hotkeys" end

    -- 解析修饰符字符串 (如果传入的是字符串)
    -- e.g., "Ctrl+Alt" -> MOD_CONTROL | MOD_ALT
    local mod_flag = 0
    if type(modifiers) == 'string' then
        local s = modifiers:lower()
        if s:find("alt") then mod_flag = bit.bor(mod_flag, 0x0001) end
        if s:find("ctrl") or s:find("control") then mod_flag = bit.bor(mod_flag, 0x0002) end
        if s:find("shift") then mod_flag = bit.bor(mod_flag, 0x0004) end
        if s:find("win") then mod_flag = bit.bor(mod_flag, 0x0008) end
    else
        mod_flag = modifiers or 0
    end

    -- 解析按键
    local vk = key
    if type(key) == 'string' and #key == 1 then
        -- 使用 VkKeyScanW 获取字符的虚拟键码
        local scan = user32.VkKeyScanW(string.byte(key:upper()))
        vk = bit.band(scan, 0xFF)
    end

    local res = user32.RegisterHotKey(nil, id, mod_flag, vk)
    if res == 0 then return nil, "RegisterHotKey failed" end

    -- 锚定回调
    anchors[id] = callback
    return id
end

function M.unregister(id)
    if user32.UnregisterHotKey(nil, id) == 0 then return false end
    anchors[id] = nil
    return true
end

-- 宿主程序收到 WM_HOTKEY 消息时调用的分发函数
function M.dispatch(id)
    local cb = anchors[id]
    if cb then
        -- 使用 xpcall 防止回调报错导致崩溃
        xpcall(cb, debug.traceback)
    end
end

-- 清理所有热键
function M.clear()
    for id, _ in pairs(anchors) do
        user32.UnregisterHotKey(nil, id)
    end
    anchors = {}
end

-- [Added] Helper to create generic callbacks (anchored)
function M.create_callback(lua_func, c_sig)
    local cb = ffi.cast(c_sig, lua_func)
    table.insert(anchors, cb)
    return cb
end

return M
