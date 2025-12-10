local M = {}

-- 延迟加载子模块映射表
local sub_modules = {
    physical  = 'win-utils.disk.physical',
    layout    = 'win-utils.disk.layout',
    geometry  = 'win-utils.disk.geometry',
    mount     = 'win-utils.disk.mount',
    format    = 'win-utils.disk.format',
    vhd       = 'win-utils.disk.vhd',
    surface   = 'win-utils.disk.surface', 
    image     = 'win-utils.disk.image',
    esp       = 'win-utils.disk.esp',
    defs      = 'win-utils.disk.defs',
    types     = 'win-utils.disk.types',
    bitlocker = 'win-utils.disk.bitlocker',
    volume    = 'win-utils.disk.volume',
    safety    = 'win-utils.disk.safety',
    info      = 'win-utils.disk.info',
    fbwf      = 'win-utils.disk.fbwf' -- [NEW] WinPE Write Filter
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        
        -- [Compat] 兼容性别名
        if key == "list" then
            local vol = require('win-utils.disk.volume')
            rawset(t, "list", vol.list_letters)
            return vol.list_letters
        end
        
        -- win.disk.info(...) 快捷方式
        if key == "info" then
            local info_mod = require('win-utils.disk.info')
            rawset(t, "info", info_mod.get)
            return info_mod.get
        end
        return nil
    end
})

-- [Internal Helper] 等待内核 PnP 识别到磁盘上的卷
local function wait_for_partitions(drive_index, timeout)
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local volume = require 'win-utils.disk.volume'
    local defs = require 'win-utils.disk.defs'
    local util = require 'win-utils.core.util'
    
    local start = kernel32.GetTickCount()
    local limit = timeout or 15000 
    
    while true do
        local vols = volume.list()
        if vols then
            for _, v in ipairs(vols) do
                local hVol = volume.open(v.guid_path)
                if hVol then
                    local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
                    hVol:close()
                    
                    if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == drive_index then
                        return true -- 卷已出现
                    end
                end
            end
        end
        if (kernel32.GetTickCount() - start) > limit then return false end
        kernel32.Sleep(250)
    end
end

-- [API] 准备磁盘 (重建分区表)
-- 流程: Unmount -> Lock -> Wipe -> Layout -> PnP Wait
-- @param drive_index: 物理磁盘索引 (0, 1, ...)
-- @param scheme: "MBR" 或 "GPT"
-- @param opts: 分区选项 (create_esp, create_msr, cluster_size 等)
function M.prepare_drive(drive_index, scheme, opts)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local layout = require 'win-utils.disk.layout'
    local device = require 'win-utils.device'
    local defs = require 'win-utils.disk.defs'

    -- 1. 卸载该磁盘上所有已挂载的卷以释放句柄
    mount.unmount_all_on_disk(drive_index)
    
    local drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    -- 2. 强力锁定 (Aggressive Lock)
    if not drive:lock(true) then 
        drive:close()
        -- 如果软锁定失败，尝试硬件复位 (USB Port Cycle / Driver Disable-Enable)
        local reset_ok, reset_msg = device.reset(drive_index, 2000)
        
        -- 复位后需要重新打开句柄
        drive, err = physical.open(drive_index, "rw", true)
        if not drive then return false, "Re-open after reset failed ("..tostring(reset_msg)..")" end
        
        if not drive:lock(true) then
            drive:close()
            return false, "Lock failed after reset"
        end
    end
    
    -- 3. 清理旧布局 (Cleaning)
    -- 擦除头部和尾部扇区，防止残留的 GPT/MBR 签名干扰
    drive:wipe_layout() 
    
    -- 发送 IOCTL_DISK_CREATE_DISK (RAW)，通知内核磁盘已变为 RAW 状态
    -- 这替代了 VDS Clean 命令，更底层且稳定
    local clean_ok, clean_err = layout.clean(drive) 
    if not clean_ok then
        drive:close()
        return false, "Layout Clean failed: " .. tostring(clean_err)
    end
    
    -- 4. 应用新布局
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok, apply_err = layout.apply(drive, scheme, plan)
    
    -- 5. 提交更改并强制刷新
    drive:flush()
    drive:ioctl(defs.IOCTL.UPDATE) -- 强制内核更新分区表缓存
    drive:close()
    
    if not ok then return false, "Layout apply failed: " .. tostring(apply_err) end

    -- 6. 等待 PnP 管理器识别新分区 (替代 VDS Refresh)
    if not wait_for_partitions(drive_index, 10000) then
        return false, "Partition polling timed out (Volumes did not arrive)"
    end
    
    return true, plan
end

-- [API] 全盘清零 (Wipe)
function M.clean_all(drive_index, cb)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    
    mount.unmount_all_on_disk(drive_index)
    local drive, err = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    local locked, lock_err = drive:lock(true)
    if not locked then 
        drive:close()
        return false, "Lock failed: " .. tostring(lock_err) 
    end
    
    local ok, w_err = drive:wipe_zero(cb)
    drive:close()
    
    return ok, w_err
end

-- [API] 磁盘健康检查 (表面扫描)
function M.check_health(drive_index, cb, write_test)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local surface = require 'win-utils.disk.surface'
    
    -- 如果是写入测试，必须卸载卷以获得独占访问
    if write_test then mount.unmount_all_on_disk(drive_index) end
    local mode = write_test and "rw" or "r"
    
    local drive, err = physical.open(drive_index, mode, true)
    if not drive then return false, "Open failed: " .. tostring(err) end
    
    -- 尝试锁定，防止其他进程干扰读取
    if not drive:lock(true) then 
        drive:close()
        return false, "Lock failed" 
    end
    
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg, stats = surface.scan(drive, cb, write_test and "write" or "read", patterns)
    drive:close()
    return ok, msg, stats
end

-- [API] 全局同步 (Flush 所有卷的缓冲区)
function M.sync()
    local volume = require 'win-utils.disk.volume'
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    
    local list = volume.list()
    if not list then return end
    
    for _, v in ipairs(list) do
        -- 仅打开需 Flush 的权限，不锁定
        local h = volume.open(v.guid_path, true)
        if h then
            kernel32.FlushFileBuffers(h:get())
            h:close()
        end
    end
end

return M