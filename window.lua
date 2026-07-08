local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'

local M = {}

M.SW = {
    hide = 0,
    normal = 1,
    minimized = 2,
    maximized = 3,
    show = 5,
    minimize = 6,
    restore = 9,
}

local SWP_NOSIZE = 0x0001
local SWP_NOMOVE = 0x0002
local SWP_NOZORDER = 0x0004

local function hwnd_value(hwnd)
    return tonumber(ffi.cast('uintptr_t', hwnd))
end

function M.get_title(hwnd)
    if not hwnd or user32.IsWindow(hwnd) == 0 then return nil end
    local len = user32.GetWindowTextLengthW(hwnd)
    if len <= 0 then return '' end
    local buf = ffi.new('wchar_t[?]', len + 1)
    user32.GetWindowTextW(hwnd, buf, len + 1)
    return util.from_wide(buf)
end

function M.get_class(hwnd)
    if not hwnd or user32.IsWindow(hwnd) == 0 then return nil end
    local buf = ffi.new('wchar_t[256]')
    if user32.GetClassNameW(hwnd, buf, 256) == 0 then return nil end
    return util.from_wide(buf)
end

function M.list(opts)
    opts = opts or {}
    local out = {}
    local cb
    cb = ffi.cast('WNDENUMPROC', function(hwnd)
        if opts.visible == false or user32.IsWindowVisible(hwnd) ~= 0 then
            local pid = ffi.new('DWORD[1]')
            user32.GetWindowThreadProcessId(hwnd, pid)
            local title = M.get_title(hwnd) or ''
            local class_name = M.get_class(hwnd) or ''
            table.insert(out, { hwnd = hwnd, hwnd_value = hwnd_value(hwnd), pid = tonumber(pid[0]), title = title, class = class_name })
        end
        return true
    end)
    user32.EnumWindows(cb, 0)
    cb:free()
    return out
end

local function match_text(value, expected, contains)
    if not expected then return true end
    value = (value or ''):lower()
    expected = tostring(expected):lower()
    if contains then return value:find(expected, 1, true) ~= nil end
    return value == expected
end

function M.find(opts)
    opts = opts or {}
    for _, item in ipairs(M.list({ visible = opts.visible })) do
        if (not opts.pid or item.pid == opts.pid)
            and match_text(item.title, opts.title, opts.contains)
            and match_text(item.class, opts.class, opts.contains) then
            return item
        end
    end
    return nil
end

function M.wait(opts, timeout)
    local start = kernel32.GetTickCount64()
    timeout = timeout or -1
    while true do
        local item = M.find(opts)
        if item then return item end
        if timeout >= 0 and (kernel32.GetTickCount64() - start) >= timeout then return nil, 'timeout' end
        kernel32.Sleep(50)
    end
end

function M.show(hwnd, mode)
    return user32.ShowWindow(hwnd, M.SW[mode] or mode or M.SW.show) ~= 0
end

function M.hide(hwnd) return M.show(hwnd, M.SW.hide) end
function M.activate(hwnd) return user32.SetForegroundWindow(hwnd) ~= 0 end
function M.close(hwnd) return user32.PostMessageW(hwnd, user32.WM_CLOSE, 0, 0) ~= 0 end

function M.move(hwnd, x, y)
    return user32.SetWindowPos(hwnd, nil, x or 0, y or 0, 0, 0, SWP_NOSIZE + SWP_NOZORDER) ~= 0
end

function M.resize(hwnd, width, height)
    return user32.SetWindowPos(hwnd, nil, 0, 0, width or 0, height or 0, SWP_NOMOVE + SWP_NOZORDER) ~= 0
end

function M.set_rect(hwnd, x, y, width, height)
    return user32.MoveWindow(hwnd, x or 0, y or 0, width or 0, height or 0, true) ~= 0
end

return M
