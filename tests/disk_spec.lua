local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestDisk = {}

function TestDisk:setUp()
    -- 检查管理员权限 (VBR 读取和 VHD 操作需要 Admin)
    self.is_admin = win.process.token.is_elevated()
    if not self.is_admin then
        print("[WARN] Skipping Disk tests (Admin required)")
    end
end

-- ========================================================================
-- 物理磁盘与 IOCTL
-- ========================================================================
function TestDisk:test_Physical_List()
    -- 列出磁盘不需要 Admin (SetupAPI)
    local drives = win.disk.physical.list()
    lu.assertIsTable(drives)
    if #drives > 0 then
        lu.assertIsNumber(drives[1].index)
        lu.assertIsNumber(drives[1].size)
    end
end

function TestDisk:test_Layout_IOCTL()
    if not self.is_admin then return end
    
    -- 尝试读取磁盘 0 的布局 (系统盘通常存在)
    local pd = win.disk.physical.open(0, "r")
    if not pd then return end -- 可能被独占锁定
    
    -- [验证] 使用纯 IOCTL 获取布局，不依赖 VDS
    local layout = win.disk.layout.get(pd)
    pd:close()
    
    lu.assertIsTable(layout)
    lu.assertTrue(layout.style == "MBR" or layout.style == "GPT")
    -- 至少应该有一个分区
    lu.assertTrue(#layout.parts > 0)
end

-- ========================================================================
-- BitLocker (Native VBR)
-- ========================================================================
function TestDisk:test_BitLocker()
    if not self.is_admin then return end
    
    -- 检测 C 盘
    -- 即使未加密，也应该返回 "None" 而不是报错
    local status = win.disk.bitlocker.get_status("C:")
    lu.assertIsString(status)
    lu.assertTrue(status == "Locked" or status == "None")
    
    local unlocked = win.disk.bitlocker.is_unlocked("C:")
    lu.assertIsBoolean(unlocked)
    
    -- 如果是系统盘，通常是解锁的（否则跑不了测试）
    lu.assertTrue(unlocked)
end

-- ========================================================================
-- 虚拟磁盘 (VHD)
-- ========================================================================
function TestDisk:test_VHD_Lifecycle()
    if not self.is_admin then return end
    
    local vhd_path = os.getenv("TEMP") .. "\\test_" .. os.time() .. ".vhdx"
    
    -- 1. Create
    local h = win.disk.vhd.create(vhd_path, 10 * 1024 * 1024) -- 10MB
    lu.assertNotNil(h, "VHD Create failed")
    
    -- 2. Attach
    local ok = win.disk.vhd.attach(h)
    lu.assertTrue(ok, "Attach failed")
    
    -- 3. Detach & Cleanup
    win.disk.vhd.detach(h)
    h:close()
    
    -- 清理文件
    os.remove(vhd_path)
end