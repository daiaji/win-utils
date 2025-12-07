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
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

    -- 0. 获取物理驱动器信息 (媒体类型)
    local drive, err = physical.open(idx, "r")
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local media_type = drive.media_type
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
    
    -- [Priority 2] Legacy (Volume GUID Path OR Mount + FMIFS)
    -- Rufus Strategy: 优先使用 Volume GUID Path (`\\?\Volume{...}`) 调用 FormatEx。
    -- 如果找不到 GUID 路径，才尝试挂载临时盘符。
    
    local target_path = nil
    local is_temp_mount = false
    
    -- 2a. 尝试通过 GUID 路径定位 (Wait up to 10s)
    for i=1, 40 do
        target_path = volume.find_guid_by_partition(idx, off)
        if target_path then break end
        kernel32.Sleep(250)
    end
    
    -- 2b. 如果 GUID 路径不可用，回退到临时盘符挂载
    if not target_path then
        target_path = mount.temp_mount(idx, off)
        if target_path then is_temp_mount = true end
    end
    
    if target_path then
        -- 确保传入正确 Media Type (Fixed/Removable)
        local ok_fmifs, msg_fmifs = fmifs.format(target_path, fs, lab, media_type)
        
        -- Post-Format Surgery: 强制设置卷标
        if ok_fmifs and lab and lab ~= "" then
            volume.set_label(target_path, lab)
        end
        
        -- NTFS 压缩支持
        if ok_fmifs and opts.compress and fs_lower == "ntfs" then
            ntfs.set_compression(target_path, true)
        end
        
        if is_temp_mount then mount.unmount(target_path) end
        
        if ok_fmifs then 
            return true, "Legacy FMIFS (" .. (is_temp_mount and "Mount" or "GUID") .. ")"
        else
            -- [STRICT] Rufus logic: Do not fallback to VDS if FMIFS failed explicitly.
            return false, "FMIFS Failed: " .. tostring(msg_fmifs)
        end
    end
    
    -- [Priority 3] VDS (Fallback / No Mount)
    -- Rufus: 仅当 Legacy 无法启动（如无法分配盘符且无 GUID）时使用。
    local ok_vds, msg_vds = vds.format(idx, off, fs, lab, true, 0, 0)
    if ok_vds then return true, "VDS (Fallback)" end
    
    return false, string.format("All strategies failed. Target: None | VDS: %s", tostring(msg_vds))
end

return M