local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}

function M.list()
    local mask = kernel32.GetLogicalDrives()
    local drives = {}
    -- 0=A, 1=B, 2=C ...
    for i = 0, 25 do
        if bit.band(mask, bit.lshift(1, i)) ~= 0 then
            table.insert(drives, string.char(65 + i) .. ":")
        end
    end
    return drives
end

function M.info(path)
    -- Normalize path to "C:\" format required by GetVolumeInformation
    local root = path or "C:\\"

    if not root:find(":\\") then
        local drive = root:match("^%a")
        if drive then
            root = drive:upper() .. ":\\"
        else
            return nil, "Invalid path format (Expected 'C:' or 'C:\')"
        end
    else
        -- Ensure trailing backslash
        if root:sub(-1) ~= "\\" then root = root .. "\\" end
    end

    local wroot = util.to_wide(root)
    local volBuf = ffi.new("wchar_t[261]")
    local fsBuf = ffi.new("wchar_t[261]")
    local serial = ffi.new("DWORD[1]")

    kernel32.GetVolumeInformationW(wroot, volBuf, 261, serial, nil, nil, fsBuf, 261)

    local type_id = kernel32.GetDriveTypeW(wroot)
    local type_map = {
        [2] = "Removable",
        [3] = "Fixed",
        [4] = "Remote",
        [5] = "CDROM",
        [6] = "RAMDisk"
    }

    -- Get Disk Space
    local free = ffi.new("ULARGE_INTEGER")
    local total = ffi.new("ULARGE_INTEGER")
    local check_path = path or root
    kernel32.GetDiskFreeSpaceExW(util.to_wide(check_path), free, total, nil)

    return {
        type = type_map[type_id] or "Unknown",
        label = util.from_wide(volBuf),
        filesystem = util.from_wide(fsBuf),
        serial = serial[0],
        -- Convert bytes to MB
        capacity_mb = tonumber(total.QuadPart) / 1048576,
        free_mb = tonumber(free.QuadPart) / 1048576
    }
end

return M
