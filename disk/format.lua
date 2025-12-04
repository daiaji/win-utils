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

    -- 0. 获取分区大小 (用于决策)
    local drive = physical.open(idx, "r")
    if not drive then return false, "Open failed" end
    local info = layout.get(drive)
    drive:close()
    
    local p_size = 0
    if info then
        for _, p in ipairs(info.parts) do
            if p.off == off then p_size = p.len; break end
        end
    end
    if p_size == 0 then return false, "Partition not found" end

    local fs_lower = fs:lower()

    -- Strategy 1: Enhanced FAT32 (Lua implementation)
    -- 如果是 FAT32 且 分区 > 32GB (Windows 限制)，优先使用 Lua 实现
    -- Windows 自带工具无法格式化 >32GB 的 FAT32，但我们的实现可以
    if fs_lower == "fat32" and p_size > 32*1024*1024*1024 then
        local ok = fat32.format_raw(idx, off, lab)
        if ok then return true, "Lua FAT32" end
    end
    
    -- Strategy 2: VDS (Modern System API)
    -- 最稳健，无需分配盘符，支持所有文件系统，是 Vista+ 的标准做法
    -- VDS 操作较慢，但最正规
    local ok_vds, msg_vds = vds.format(idx, off, fs, lab, true, 0, 0)
    if ok_vds then return true, "VDS" end
    
    -- Strategy 3: Legacy (Mount + FMIFS)
    -- 如果 VDS 失败（例如服务不可用），回退到传统的挂载+API格式化
    local letter = mount.temp_mount(idx, off)
    if letter then
        local ok_fmifs = fmifs.format(letter, fs, lab)
        
        -- NTFS 压缩支持
        if ok_fmifs and opts.compress and fs_lower == "ntfs" then
            ntfs.set_compression(letter, true)
        end
        
        mount.unmount(letter)
        if ok_fmifs then return true, "Legacy FMIFS" end
    end
    
    return false, "All strategies failed (VDS: " .. tostring(msg_vds) .. ")"
end

return M