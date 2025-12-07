local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local volume = require 'win-utils.disk.volume'

local M = {}

-- [RESTORED] 聚合查询函数
-- @param root: "C:", "C:\", etc.
-- @return: table { label, type, filesystem, serial, total_mb, free_mb }
function M.get(root)
    if not root then return nil, "Root path required" end
    local path = root
    if not path:match("[\\/]$") then path = path .. "\\" end
    
    local wpath = util.to_wide(path)
    
    -- 1. Volume Info
    local volBuf = ffi.new("wchar_t[261]")
    local fsBuf = ffi.new("wchar_t[261]")
    local serial = ffi.new("DWORD[1]")
    
    kernel32.GetVolumeInformationW(wpath, volBuf, 261, serial, nil, nil, fsBuf, 261)
    
    -- 2. Drive Type
    -- reuse get_type from volume module logic
    local t_id = kernel32.GetDriveTypeW(wpath)
    local type_map = {
        [2] = "Removable",
        [3] = "Fixed",
        [4] = "Remote",
        [5] = "CDROM",
        [6] = "RAMDisk"
    }
    
    -- 3. Space Info
    local free = ffi.new("ULARGE_INTEGER")
    local total = ffi.new("ULARGE_INTEGER")
    kernel32.GetDiskFreeSpaceExW(wpath, free, total, nil)
    
    return {
        label = util.from_wide(volBuf),
        filesystem = util.from_wide(fsBuf),
        type = type_map[t_id] or "Unknown",
        serial = serial[0],
        total_mb = tonumber(total.QuadPart) / 1048576,
        free_mb = tonumber(free.QuadPart) / 1048576
    }
end

return M