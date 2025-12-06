local ffi = require 'ffi'
local bit = require 'bit'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local class = require 'win-utils.deps'.class

-- [FFI Definitions] -----------------------------------------------------------
ffi.cdef [[
    typedef void* HDEVNOTIFY;
    
    typedef struct _DEV_BROADCAST_HDR {
        DWORD dbch_size;
        DWORD dbch_devicetype;
        DWORD dbch_reserved;
    } DEV_BROADCAST_HDR;

    typedef struct _DEV_BROADCAST_DEVICEINTERFACE_W {
        DWORD dbch_size;
        DWORD dbch_devicetype;
        DWORD dbch_reserved;
        GUID  dbcc_classguid;
        wchar_t dbcc_name[1];
    } DEV_BROADCAST_DEVICEINTERFACE_W;

    HDEVNOTIFY RegisterDeviceNotificationW(HANDLE hRecipient, void* NotificationFilter, DWORD Flags);
    BOOL UnregisterDeviceNotification(HDEVNOTIFY Handle);
    
    HWND CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
    BOOL DestroyWindow(HWND hWnd);
    LRESULT DefWindowProcW(HWND, UINT, WPARAM, LPARAM);
]]

local M = {}
local C = ffi.C

-- Constants
local DBT_DEVTYP_DEVICEINTERFACE = 0x00000005
local DBT_DEVICEARRIVAL          = 0x8000
local DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000
local WM_DEVICECHANGE            = 0x0219
local GUID_DEVINTERFACE_VOLUME   = ffi.new("GUID", {0x53F5630D, 0xB6BF, 0x11D0, {0x94, 0xF2, 0x00, 0xA0, 0xC9, 0x1E, 0xFB, 0x8B}})

-- [PnP Watcher Class] ---------------------------------------------------------
local PnpWatcher = class()

function PnpWatcher:init()
    -- 1. 创建一个 Message-Only 窗口 (使用系统预定义的 "Static" 类，省去注册类的麻烦)
    self.hwnd = C.CreateWindowExW(0, util.to_wide("Static"), nil, 0, 0, 0, 0, 0, ffi.cast("HWND", -3), nil, nil, nil)
    if self.hwnd == nil then error("CreateWindow failed: " .. util.last_error()) end

    -- 2. 构造过滤结构体，只监听 "Volume" 类型的接口事件
    local filter = ffi.new("DEV_BROADCAST_DEVICEINTERFACE_W")
    filter.dbch_size = ffi.sizeof(filter)
    filter.dbch_devicetype = DBT_DEVTYP_DEVICEINTERFACE
    filter.dbcc_classguid = GUID_DEVINTERFACE_VOLUME

    -- 3. 注册通知
    self.hNotify = C.RegisterDeviceNotificationW(self.hwnd, filter, DEVICE_NOTIFY_WINDOW_HANDLE)
    if self.hNotify == nil then 
        C.DestroyWindow(self.hwnd)
        error("RegisterDeviceNotification failed: " .. util.last_error()) 
    end
end

function PnpWatcher:wait(timeout_ms)
    local start = kernel32.GetTickCount()
    local limit = timeout_ms or 5000
    local msg = ffi.new("MSG")
    
    -- 4. 消息泵循环 (Event Loop)
    while true do
        local elapsed = kernel32.GetTickCount() - start
        if elapsed > limit then return false, "Timeout" end
        
        local remaining = limit - elapsed
        
        -- 等待消息到达 (类似于 Linux 的 epoll/select)
        -- MWMO_INPUTAVAILABLE = 4, MWMO_ALERTABLE = 2
        local wait_res = user32.MsgWaitForMultipleObjects(0, nil, false, remaining, 0x0404)
        
        if wait_res == 258 then -- WAIT_TIMEOUT
            return false, "Timeout"
        end
        
        -- 处理消息队列
        while user32.PeekMessageW(msg, self.hwnd, 0, 0, 1) ~= 0 do -- PM_REMOVE
            if msg.message == WM_DEVICECHANGE then
                -- 如果是设备到达事件，立即返回 true
                if msg.wParam == DBT_DEVICEARRIVAL then
                    -- 可以在这里解析 msg.lParam 获取具体是哪个卷，
                    -- 但为了简化，只要有卷变动我们就通知上层去 Check
                    return true, "Arrival"
                end
            end
            user32.TranslateMessage(msg)
            user32.DispatchMessageW(msg)
        end
    end
end

function PnpWatcher:close()
    if self.hNotify then C.UnregisterDeviceNotification(self.hNotify); self.hNotify = nil end
    if self.hwnd then C.DestroyWindow(self.hwnd); self.hwnd = nil end
end

-- [API] -----------------------------------------------------------------------

-- 智能等待：监听系统事件，直到超时或有新卷到达
function M.wait_for_volume_change(timeout)
    local w = nil
    local ok, res, err = pcall(function()
        w = PnpWatcher()
        return w:wait(timeout)
    end)
    if w then w:close() end
    if not ok then return false, res end
    return res, err
end

return M