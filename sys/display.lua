local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local ccd = require 'ffi.req' 'Windows.sdk.ccd'
local bit = require 'bit'
local util = require 'win-utils.core.util'
local M = {}

-- [API] 设置分辨率
-- @param w: 宽度
-- @param h: 高度
-- @param hz: 刷新率 (可选)
-- @param depth: 颜色位深 (可选, e.g. 16, 32)
function M.set_res(w, h, hz, depth)
    local dm = ffi.new("DEVMODEW")
    dm.dmSize = ffi.sizeof(dm)
    
    -- DM_PELSWIDTH (0x00080000) | DM_PELSHEIGHT (0x00100000)
    dm.dmPelsWidth = w
    dm.dmPelsHeight = h
    dm.dmFields = 0x180000 
    
    if hz then 
        dm.dmDisplayFrequency = hz
        -- DM_DISPLAYFREQUENCY (0x00400000)
        dm.dmFields = bit.bor(dm.dmFields, 0x400000) 
    end
    
    if depth then
        dm.dmBitsPerPel = depth
        -- DM_BITSPERPEL (0x00040000)
        dm.dmFields = bit.bor(dm.dmFields, 0x040000)
    end
    
    -- CDS_UPDATEREGISTRY (0x01)
    local res = user32.ChangeDisplaySettingsExW(nil, dm, nil, 0x01, nil)
    if res ~= 0 then return false, "ChangeDisplaySettings failed code: " .. res end
    return true
end

function M.set_topology(mode)
    local f = 0x80 -- SDC_APPLY
    if mode=="clone" then f=bit.bor(f,2) -- SDC_TOPOLOGY_CLONE
    elseif mode=="extend" then f=bit.bor(f,4) -- SDC_TOPOLOGY_EXTEND
    elseif mode=="external" then f=bit.bor(f,8) -- SDC_TOPOLOGY_EXTERNAL
    else f=bit.bor(f,1) -- SDC_TOPOLOGY_INTERNAL
    end 
    
    local res = ccd.SetDisplayConfig(0, nil, 0, nil, f)
    if res ~= 0 then return false, "SetDisplayConfig failed code: " .. res end
    return true
end

-- [API] 获取支持的显示模式列表
-- @return: table list of { w, h, hz, bpp }
function M.get_modes()
    local modes = {}
    local i = 0
    local dm = ffi.new("DEVMODEW")
    dm.dmSize = ffi.sizeof(dm)
    
    -- 枚举主显示器 (DeviceName=nil)
    while user32.EnumDisplaySettingsW(nil, i, dm) ~= 0 do
        table.insert(modes, {
            w = tonumber(dm.dmPelsWidth),
            h = tonumber(dm.dmPelsHeight),
            hz = tonumber(dm.dmDisplayFrequency),
            bpp = tonumber(dm.dmBitsPerPel)
        })
        i = i + 1
    end
    return modes
end

return M