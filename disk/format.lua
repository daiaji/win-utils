local M = {}

-- 辅助：检查卷是否已拥有有效的文件系统
local function is_filesystem_ready(idx, offset, expected_fs)
    local volume = require 'win-utils.disk.volume'
    local guid = volume.find_guid_by_partition(idx, offset)
    if not guid then return false end
    
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local ffi = require 'ffi'
    local util = require 'win-utils.core.util'
    
    local path = util.to_wide(guid:sub(-1)=="\\" and guid or guid.."\\")
    local fs_buf = ffi.new("wchar_t[261]")
    
    -- 尝试读取卷信息
    if kernel32.GetVolumeInformationW(path, nil, 0, nil, nil, nil, fs_buf, 261) ~= 0 then
        local detected = util.from_wide(fs_buf)
        if detected and detected:upper() == expected_fs:upper() then
            return true
        end
    end
    return false
end

-- 格式化统一入口
function M.format(idx, off, fs, lab, opts)
    opts = opts or {}
    local mount = require 'win-utils.disk.mount'
    local vds = require 'win-utils.disk.vds'
    local fat32 = require 'win-utils.disk.format.fat32'
    local fmifs = require 'win-utils.disk.format.fmifs'
    local physical = require 'win-utils.disk.physical'
    local layout = require 'win-utils.disk.layout'
    local ntfs = require 'win-utils.fs.ntfs'

    local drive, err = physical.open(idx, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local info, l_err = layout.get(drive)
    
    if not info then 
        drive:close()
        return false, "GetLayout failed: " .. tostring(l_err) 
    end
    
    local p_size = 0
    for _, p in ipairs(info.parts) do
        if p.off == off then p_size = p.len; break end
    end
    if p_size == 0 then 
        drive:close()
        return false, "Partition not found at offset " .. off 
    end

    local fs_lower = fs:lower()
    local result = false
    local msg = "Unknown Error"
    
    -- [Rufus Strategy] 格式化前刷新
    drive:refresh()
    drive:close() -- 必须关闭句柄，否则格式化可能失败

    -- Strategy 1: Enhanced FAT32
    if fs_lower == "fat32" and p_size > 32*1024*1024*1024 then
        local ok, f_err = fat32.format_raw(idx, off, lab)
        if ok then 
            result = true; msg = "Lua FAT32"
            goto done
        end
    end
    
    -- Strategy 2: VDS
    local ok_vds, msg_vds = vds.format(idx, off, fs, lab, true, 0, 0)
    if ok_vds then
        if is_filesystem_ready(idx, off, fs) then
            result = true; msg = "VDS"
            goto done
        else
            msg_vds = "VDS succeeded but filesystem is RAW"
        end
    end
    
    -- Strategy 3: Legacy
    local letter = mount.temp_mount(idx, off)
    if letter then
        local ok_fmifs, msg_fmifs = fmifs.format(letter, fs, lab)
        if ok_fmifs and opts.compress and fs_lower == "ntfs" then
            ntfs.set_compression(letter, true)
        end
        mount.unmount(letter)
        if ok_fmifs then 
            result = true; msg = "Legacy FMIFS"
            goto done
        end
        msg = "Legacy FMIFS failed: " .. tostring(msg_fmifs) .. " (VDS was: " .. tostring(msg_vds) .. ")"
    else
        msg = "VDS Error: " .. tostring(msg_vds)
    end

    ::done::
    -- [Rufus Strategy] 格式化后再次刷新
    local d2 = physical.open(idx, "r", true)
    if d2 then 
        d2:refresh()
        d2:close() 
    end
    
    return result, msg
end

return M