local ffi = require 'ffi'
local bit = require 'bit'
local ccd = require 'ffi.req' 'Windows.sdk.ccd'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- 设置多显示器拓扑 (Clone/Extend/Internal/External)
-- @param mode: "internal" (DISP S1), "clone" (DISP S2), "extend" (DISP S3), "external"
function M.set_topology(mode)
    local flag_map = {
        internal = C.SDC_TOPOLOGY_INTERNAL,
        clone    = C.SDC_TOPOLOGY_CLONE,
        extend   = C.SDC_TOPOLOGY_EXTEND,
        external = C.SDC_TOPOLOGY_EXTERNAL
    }
    
    local topology = flag_map[mode]
    if not topology then return false, "Invalid topology mode" end
    
    local flags = bit.bor(C.SDC_APPLY, topology)
    
    local res = ccd.SetDisplayConfig(0, nil, 0, nil, flags)
    if res ~= 0 then return false, util.format_error(res) end
    return true
end

-- 设置分辨率 (Legacy API - 兼容性好，适合 PE)
-- @param width: 宽度 (e.g. 1920)
-- @param height: 高度 (e.g. 1080)
-- @param freq: 刷新率 (可选)
-- @param bit_depth: 颜色位深 (可选, e.g. 32)
function M.set_resolution(width, height, freq, bit_depth)
    local dm = ffi.new("DEVMODEW")
    dm.dmSize = ffi.sizeof(dm)
    
    -- 获取当前设置作为基准
    if user32.EnumDisplaySettingsW(nil, -1, dm) == 0 then -- ENUM_CURRENT_SETTINGS = -1
        return false, "EnumDisplaySettings failed"
    end
    
    local fields = 0
    
    if width and height then
        dm.dmPelsWidth = width
        dm.dmPelsHeight = height
        fields = bit.bor(fields, 0x00080000, 0x00100000) -- DM_PELSWIDTH | DM_PELSHEIGHT
    end
    
    if freq and freq > 0 then
        dm.dmDisplayFrequency = freq
        fields = bit.bor(fields, 0x00400000) -- DM_DISPLAYFREQUENCY
    end
    
    if bit_depth and bit_depth > 0 then
        dm.dmBitsPerPel = bit_depth
        fields = bit.bor(fields, 0x00040000) -- DM_BITSPERPEL
    end
    
    dm.dmFields = fields
    
    -- CDS_UPDATEREGISTRY = 0x01
    local res = user32.ChangeDisplaySettingsExW(nil, dm, nil, 0x01, nil)
    
    if res == 0 then return true end
    if res == 1 then return false, "Restart required" end -- DISP_CHANGE_RESTART
    return false, "Failed with code: " .. res
end

return M