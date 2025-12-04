local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestDisk = {}

function TestDisk:setUp()
    self.is_admin = win.process.token.is_elevated()
    if not self.is_admin then
        print("\n[WARN] Non-Admin environment: Skipping physical disk tests")
    end
    
    local drives = win.disk.physical.list()
    self.has_drives = (#drives > 0)
end

function TestDisk:test_Physical_List()
    local drives = win.disk.physical.list()
    lu.assertIsTable(drives)
end

function TestDisk:test_Layout_IOCTL()
    if not self.is_admin or not self.has_drives then return end
    
    local pd = win.disk.physical.open(0, "r")
    if not pd then return end 
    
    local layout = win.disk.layout.get(pd)
    pd:close()
    
    if layout then
        lu.assertIsTable(layout)
        lu.assertTrue(layout.style == "MBR" or layout.style == "GPT")
    end
end

-- [找回的部分] BitLocker 检测
function TestDisk:test_BitLocker()
    if not self.is_admin then return end
    
    -- 尝试检测 C: (系统盘通常存在)
    -- CI 环境下 C: 可能是虚拟的，不一定有标准的 VBR
    local ok, status = pcall(function() 
        return win.disk.bitlocker.get_status("C:") 
    end)
    
    if ok and status then
        lu.assertIsString(status)
        lu.assertTrue(status == "Locked" or status == "None")
        
        local unlocked = win.disk.bitlocker.is_unlocked("C:")
        lu.assertIsBoolean(unlocked)
    else
        print("[INFO] BitLocker check skipped (Virtual Volume/No Access)")
    end
end

function TestDisk:test_VHD_Lifecycle()
    if not self.is_admin then return end
    
    local vhd_path = os.getenv("TEMP") .. "\\test_" .. os.time() .. ".vhdx"
    
    local h, err = win.disk.vhd.create(vhd_path, 10 * 1024 * 1024)
    if not h then
        print("[SKIP] VHD Create failed (VirtDisk disabled?): " .. tostring(err))
        return
    end
    lu.assertNotNil(h)
    
    local ok = win.disk.vhd.attach(h)
    if not ok then
        print("[INFO] VHD Created but Attach failed (Driver missing)")
    else
        win.disk.vhd.detach(h)
    end
    
    h:close()
    os.remove(vhd_path)
end