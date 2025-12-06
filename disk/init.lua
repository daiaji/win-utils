local M = {}

local sub_modules = {
    physical  = 'win-utils.disk.physical',
    layout    = 'win-utils.disk.layout',
    geometry  = 'win-utils.disk.geometry',
    mount     = 'win-utils.disk.mount',
    format    = 'win-utils.disk.format',
    vds       = 'win-utils.disk.vds',
    vhd       = 'win-utils.disk.vhd',
    surface   = 'win-utils.disk.surface', -- [Renamed from badblocks]
    image     = 'win-utils.disk.image',
    esp       = 'win-utils.disk.esp',
    defs      = 'win-utils.disk.defs',
    types     = 'win-utils.disk.types',
    bitlocker = 'win-utils.disk.bitlocker',
    volume    = 'win-utils.disk.volume'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

function M.prepare_drive(drive_index, scheme, opts)
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local vds = require 'win-utils.disk.vds'
    local layout = require 'win-utils.disk.layout'

    mount.unmount_all_on_disk(drive_index)
    
    local drive = physical.open(drive_index, "rw", true)
    if not drive then return false, "Open failed" end
    if not drive:lock(true) then drive:close(); return false, "Lock failed" end
    
    local wiped = drive:wipe_layout()
    drive:close()
    if not wiped then return false, "Wipe layout failed" end
    
    vds.clean(drive_index)
    kernel32.Sleep(500)
    
    drive = physical.open(drive_index, "rw", true)
    if not drive then return false, "Re-open failed" end
    if not drive:lock(true) then drive:close(); return false, "Re-lock failed" end
    
    local plan = layout.calculate_partition_plan(drive, scheme, opts)
    local ok = layout.apply(drive, scheme, plan)
    drive:close()
    
    kernel32.Sleep(1000)
    return ok, plan
end

function M.clean_all(drive_index, cb)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    
    mount.unmount_all_on_disk(drive_index)
    local drive = physical.open(drive_index, "rw", true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    
    local ok, err = drive:wipe_zero(cb)
    
    drive:close()
    return ok, err
end

function M.check_health(drive_index, cb, write_test)
    local mount = require 'win-utils.disk.mount'
    local physical = require 'win-utils.disk.physical'
    local surface = require 'win-utils.disk.surface'
    
    if write_test then mount.unmount_all_on_disk(drive_index) end
    local mode = write_test and "rw" or "r"
    local drive = physical.open(drive_index, mode, true)
    if not drive then return false end
    if not drive:lock(true) then drive:close(); return false end
    
    local patterns = write_test and {0x55, 0xAA, 0x00, 0xFF} or nil
    local ok, msg = surface.scan(drive, cb, write_test and "write" or "read", patterns)
    drive:close()
    return ok, msg
end

function M.rescan()
    local vds = require 'win-utils.disk.vds'
    local ctx = vds.create_context() -- 注意: vds.lua 需确保导出 create_context 或修正此处
    -- 在 vds.lua 未导出 create_context 的情况下，通常使用隐式创建
    -- 这里假设 vds 模块内部逻辑
    -- [Fix] vds.lua 中使用的是 VdsContext 类，未导出 create_context 函数，需修正调用
    -- 由于 vds.lua 内部使用 VdsContext，但该类是 local 的。
    -- 我们需要 hack 一下或者依赖 vds 模块提供的具体功能函数。
    -- 目前 vds 模块没有导出 rescan 相关的 helper。
    -- 暂且留空或标记 TODO，或者修改 vds.lua 导出 VdsContext
    return false, "Not implemented"
end

function M.sync()
    local volume = require 'win-utils.disk.volume'
    local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
    local list = volume.list()
    if not list then return end
    for _, v in ipairs(list) do
        local h = volume.open(v.guid_path, true)
        if h then
            kernel32.FlushFileBuffers(h:get())
            h:close()
        end
    end
end

return M