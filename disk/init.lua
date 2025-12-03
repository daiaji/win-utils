local M = {}

print("[DEBUG] Loading win-utils.disk (Eager Mode)...")

-- 显式加载所有子模块
local function req(name)
    print("[DEBUG]   - disk." .. name)
    return require('win-utils.disk.' .. name)
end

M.volume    = req('volume')
M.info      = req('info')
M.physical  = req('physical')
M.layout    = req('layout')
M.vds       = req('vds')
M.vhd       = req('vhd')
M.format    = req('format.init')
M.badblocks = req('badblocks')
M.types     = req('types')
M.defs      = req('defs')
M.safety    = req('safety')
M.subst     = req('subst')
M.mount     = req('mount')
M.esp       = req('esp')
M.op        = req('operation')

-- [FIX] 补充测试中依赖的别名 (Facade Methods)
print("[DEBUG] Binding facade methods for win-utils.disk...")

if M.info and M.info.list_physical_drives then
    M.list_drives = M.info.list_physical_drives
    print("[DEBUG]   + list_drives -> info.list_physical_drives (OK)")
else
    print("[ERROR]   ! info.list_physical_drives MISSING")
end

if M.op then
    -- 转发常用的操作函数到 disk 命名空间
    M.prepare_drive = M.op.prepare_drive
    M.format_partition = M.op.format_partition
    M.clean_all = M.op.clean_all
end

print("[DEBUG] win-utils.disk loaded.")
return M