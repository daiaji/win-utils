local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'

local M = {}

M.VK = {
    BACK = 0x08, TAB = 0x09, ENTER = 0x0D, SHIFT = 0x10, CTRL = 0x11, ALT = 0x12,
    PAUSE = 0x13, CAPSLOCK = 0x14, ESC = 0x1B, SPACE = 0x20, PAGEUP = 0x21, PAGEDOWN = 0x22,
    END = 0x23, HOME = 0x24, LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28,
    INSERT = 0x2D, DELETE = 0x2E, NUMLOCK = 0x90, SCROLLLOCK = 0x91,
    LWIN = 0x5B, RWIN = 0x5C,
}
for i = 0, 9 do M.VK[tostring(i)] = 0x30 + i end
for b = string.byte('A'), string.byte('Z') do M.VK[string.char(b)] = b end
for i = 1, 24 do M.VK['F' .. i] = 0x6F + i end

local KEYEVENTF_EXTENDEDKEY = 0x0001
local KEYEVENTF_KEYUP = 0x0002
local KEYEVENTF_UNICODE = 0x0004
local INPUT_KEYBOARD = 1
local MOUSEEVENTF_MOVE = 0x0001
local MOUSEEVENTF_LEFTDOWN = 0x0002
local MOUSEEVENTF_LEFTUP = 0x0004
local MOUSEEVENTF_RIGHTDOWN = 0x0008
local MOUSEEVENTF_RIGHTUP = 0x0010
local MOUSEEVENTF_MIDDLEDOWN = 0x0020
local MOUSEEVENTF_MIDDLEUP = 0x0040
local MOUSEEVENTF_WHEEL = 0x0800
local MOUSEEVENTF_ABSOLUTE = 0x8000

local function vk(key)
    if type(key) == 'number' then return key end
    return M.VK[tostring(key):upper()]
end

function M.key_down(key)
    local code = vk(key)
    if not code then return false, 'Unknown key: ' .. tostring(key) end
    user32.keybd_event(code, user32.MapVirtualKeyW(code, 0), 0, 0)
    return true
end

function M.key_up(key)
    local code = vk(key)
    if not code then return false, 'Unknown key: ' .. tostring(key) end
    user32.keybd_event(code, user32.MapVirtualKeyW(code, 0), KEYEVENTF_KEYUP, 0)
    return true
end

function M.send_key(key)
    local ok, err = M.key_down(key)
    if not ok then return false, err end
    return M.key_up(key)
end

function M.send_combo(keys)
    for _, key in ipairs(keys) do local ok, err = M.key_down(key); if not ok then return false, err end end
    for i = #keys, 1, -1 do M.key_up(keys[i]) end
    return true
end

function M.send_text(text)
    local w = util.to_wide(text or '')
    if not w then return false, 'Invalid text' end
    local len = 0
    while w[len] ~= 0 do len = len + 1 end
    if len == 0 then return true end

    local inputs = ffi.new('INPUT[?]', len * 2)
    for i = 0, len - 1 do
        inputs[i * 2].type = INPUT_KEYBOARD
        inputs[i * 2].DUMMYUNIONNAME.ki.wScan = w[i]
        inputs[i * 2].DUMMYUNIONNAME.ki.dwFlags = KEYEVENTF_UNICODE
        inputs[i * 2 + 1].type = INPUT_KEYBOARD
        inputs[i * 2 + 1].DUMMYUNIONNAME.ki.wScan = w[i]
        inputs[i * 2 + 1].DUMMYUNIONNAME.ki.dwFlags = bit.bor(KEYEVENTF_UNICODE, KEYEVENTF_KEYUP)
    end
    return user32.SendInput(len * 2, inputs, ffi.sizeof('INPUT')) == len * 2
end

function M.get_key_state(key)
    local code = vk(key)
    if not code then return nil, 'Unknown key: ' .. tostring(key) end
    local state = tonumber(user32.GetKeyState(code))
    return { down = bit.band(state, 0x8000) ~= 0, toggled = bit.band(state, 1) ~= 0, raw = state }
end

function M.set_toggle_key(key, enabled)
    local state, err = M.get_key_state(key)
    if not state then return false, err end
    if state.toggled ~= enabled then return M.send_key(key) end
    return true
end

function M.move_mouse(dx, dy, absolute)
    local flags = absolute and (MOUSEEVENTF_MOVE + MOUSEEVENTF_ABSOLUTE) or MOUSEEVENTF_MOVE
    user32.mouse_event(flags, dx or 0, dy or 0, 0, 0)
    return true
end

function M.click(button)
    button = (button or 'left'):lower()
    local down, up
    if button == 'left' then down, up = MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP
    elseif button == 'right' then down, up = MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP
    elseif button == 'middle' then down, up = MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP
    else return false, 'Unknown mouse button: ' .. tostring(button) end
    user32.mouse_event(down, 0, 0, 0, 0)
    user32.mouse_event(up, 0, 0, 0, 0)
    return true
end

function M.wheel(delta)
    user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, delta or 120, 0)
    return true
end

return M
