local M = {}

-- 格式化统一入口
-- @param idx: 物理驱动器索引
-- @param off: 分区字节偏移量
-- @param fs: 文件系统 (NTFS/FAT32/ExFAT)
-- @param lab: 卷标
-- @param opts: 额外选项 { quick=true, compress=false }
function M.format(idx, off, fs, lab, opts)
    opts = opts or {}
    local mount = require 'win-utils.disk.mount'
    local vds = require 'win-utils.disk.vds'
    local fat32 = require 'win-utils.disk.format.fat32'
    local fmifs = require 'win-utils.disk.format.fmifs'
    local physical = require 'win-utils.disk.physical'
    local layout = require 'win-utils.disk.layout'

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

    -- Strategy 1: Enhanced FAT32 (Lua implementation)
    -- 仅当文件系统为 FAT32 且分区大于 32GB (Windows 限制) 时优先使用
    if fs:lower() == "fat32" and p_size > 32*1024*1024*1024 then
        local ok = fat32.format_raw(idx, off, lab)
        if ok then return true, "Lua FAT32" end
    end
    
    -- Strategy 2: VDS (Modern System API)
    -- 最稳健，无需分配盘符，支持所有文件系统
    local ok_vds, msg_vds = vds.format(idx, off, fs, lab, true, 0, 0)
    if ok_vds then return true, "VDS" end
    
    -- Strategy 3: Legacy (Mount + FMIFS)
    -- 最后尝试挂载临时盘符并使用 FormatEx
    local letter = mount.temp_mount(idx, off)
    if letter then
        local ok_fmifs = fmifs.format(letter, fs, lab)
        -- 如果是 NTFS 且请求压缩
        if ok_fmifs and opts.compress and fs:lower() == "ntfs" then
            require('win-utils.fs.ntfs').set_compression(letter, true)
        end
        mount.unmount(letter)
        if ok_fmifs then return true, "Legacy FMIFS" end
    end
    
    return false, "All strategies failed"
end

return M