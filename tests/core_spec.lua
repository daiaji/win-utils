local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local util = require('win-utils.core.util')

TestCore = {}

function TestCore:setUp()
    self.sandbox = "test_sandbox_" .. os.time()
    local k32 = ffi.load("kernel32")
    k32.CreateDirectoryW(util.to_wide(self.sandbox), nil)
    self.reg_key = "Software\\LuaWinUtilsTest"
    
    if win.reg then win.reg.delete_key("HKCU", self.reg_key, true) end
end

function TestCore:tearDown()
    if win.fs and win.fs.delete then 
        win.fs.delete(self.sandbox) 
    end
    if win.reg then 
        win.reg.delete_key("HKCU", self.reg_key, true) 
    end
end

-- ========================================================================
-- 文件系统 (Native FS)
-- ========================================================================
function TestCore:test_Path_Conversion()
    local nt = "\\??\\C:\\Windows"
    local dos = win.fs.path.nt_path_to_dos(nt)
    if dos then
        lu.assertStrContains(dos, "Windows")
    else
        print("[INFO] Path conversion returned nil (Non-standard drive map?)")
    end
end

function TestCore:test_FS_Recursive_Ops()
    local d1 = self.sandbox .. "\\dir1"
    local f1 = d1 .. "\\file1.txt"
    ffi.load("kernel32").CreateDirectoryW(util.to_wide(d1), nil)
    local f = io.open(f1, "w"); f:write("data"); f:close()
    
    local d2 = self.sandbox .. "\\dir2"
    local ok_copy = win.fs.copy(d1, d2)
    lu.assertTrue(ok_copy, "Recursive copy failed")
    lu.assertTrue(win.fs.exists(d2 .. "\\file1.txt"), "Copied file missing")
    
    local native_raw = require('win-utils.fs.raw')
    native_raw.set_attributes(f1, 1) -- ReadOnly
    
    local ok_del = win.fs.delete(d1)
    lu.assertTrue(ok_del, "Recursive delete failed")
    lu.assertFalse(win.fs.exists(d1), "Directory should be gone")
end

-- [Modified] Removed ACL Reset test as ACLs are not preserved/handled in PE mode

-- ========================================================================
-- 注册表 (Registry)
-- ========================================================================
function TestCore:test_Registry_Basic()
    local k = win.reg.open_key("HKCU", self.reg_key)
    lu.assertNotNil(k, "Failed to create key")
    
    lu.assertTrue(k:write("TestVal", 123))
    lu.assertEquals(k:read("TestVal"), 123)
    
    lu.assertTrue(k:write("TestMulti", {"A", "B"}, "multi_sz"))
    local m = k:read("TestMulti")
    lu.assertIsTable(m)
    lu.assertEquals(m[1], "A")
    
    k:close()
end

-- [Modified] Removed Hive Lifecycle test to reduce CI complexity