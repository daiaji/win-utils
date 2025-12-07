local M = {}

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
    local volume = require 'win-utils.disk.volume'

    -- 0. 获取分区大小 (用于决策)
    local drive, err = physical.open(idx, "r")
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local info, l_err = layout.get(drive)
    drive:close()
    
    if not info then return false, "GetLayout failed: " .. tostring(l_err) end
    
    local p_size = 0
    for _, p in ipairs(info.parts) do
        if p.off == off then p_size = p.len; break end
    end
    if p_size == 0 then return false, "Partition not found at offset " .. off end

    local fs_lower = fs:lower()

    -- [Priority 1] Enhanced FAT32 (Lua implementation)
    -- Rufus: 只有当 FAT32 > 32GB 时才强制使用，因为 Windows FormatEx 此时会人为限制。
    if fs_lower == "fat32" and p_size > 32*1024*1024*1024 then
        local ok, f_err = fat32.format_raw(idx, off, lab)
        if ok then return true, "Lua FAT32" end
    end
    
    -- [Priority 2] Legacy (Mount + FMIFS)
    -- Rufus: 默认首选。虽然需要盘符，但它是同步的，且不会受 VDS 缓存延迟影响。
    
    -- 尝试挂载临时盘符
    local letter = mount.temp_mount(idx, off)
    if letter then
        local ok_fmifs, msg_fmifs = fmifs.format(letter, fs, lab)
        
        -- Post-Format Surgery: 强制设置卷标
        if ok_fmifs and lab and lab ~= "" then
            volume.set_label(letter, lab)
        end
        
        -- NTFS 压缩支持
        if ok_fmifs and opts.compress and fs_lower == "ntfs" then
            ntfs.set_compression(letter, true)
        end
        
        mount.unmount(letter)
        
        if ok_fmifs then 
            return true, "Legacy FMIFS" 
        else
            -- [STRICT] Rufus logic: Do not fallback to VDS if FMIFS failed explicitly.
            -- This exposes the real error (e.g. Write Protected, IO Error) instead of masking it with a VDS generic error.
            return false, "FMIFS Failed: " .. tostring(msg_fmifs)
        end
    end
    
    -- [Priority 3] VDS (Fallback / No Mount)
    -- Rufus: 仅当 Legacy 无法启动（如无法分配盘符）时使用。
    -- VDS 不需要盘符，可以直接通过 GUID 操作。
    local ok_vds, msg_vds = vds.format(idx, off, fs, lab, true, 0, 0)
    if ok_vds then return true, "VDS (Fallback)" end
    
    return false, string.format("All strategies failed. Mount: No letter | VDS: %s", tostring(msg_vds))
end

return M