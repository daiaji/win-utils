local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
-- [FIX] 引用路径修正
local util = require('win-utils.core.util')

TestCore = {}

function TestCore:setUp()
    self.sandbox = "test_sandbox_" .. os.time()
    local k32 = ffi.load("kernel32")
    k32.CreateDirectoryW(util.to_wide(self.sandbox), nil)
    self.reg_key = "Software\\LuaWinUtilsTest"
    
    -- 确保测试前注册表干净
    if win.reg then win.reg.delete_key("HKCU", self.reg_key, true) end
end

function TestCore:tearDown()
    -- [验证] 使用新的 Native 递归删除清理沙盒
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
    lu.assertStrContains(dos or "", "C:\\Windows")
end

function TestCore:test_FS_Recursive_Ops()
    -- 1. 创建目录树
    local d1 = self.sandbox .. "\\dir1"
    local f1 = d1 .. "\\file1.txt"
    ffi.load("kernel32").CreateDirectoryW(util.to_wide(d1), nil)
    local f = io.open(f1, "w"); f:write("data"); f:close()
    
    -- 2. 测试 Native 递归复制
    local d2 = self.sandbox .. "\\dir2"
    local ok_copy = win.fs.copy(d1, d2)
    lu.assertTrue(ok_copy, "Recursive copy failed")
    lu.assertTrue(win.fs.exists(d2 .. "\\file1.txt"), "Copied file missing")
    
    -- 3. 测试 Native 暴力删除 (rm_rf)
    -- 设置只读属性以增加难度
    local native_raw = require('win-utils.fs.raw')
    native_raw.set_attributes(f1, 1) -- ReadOnly
    
    local ok_del = win.fs.delete(d1)
    lu.assertTrue(ok_del, "Recursive delete failed")
    lu.assertFalse(win.fs.exists(d1), "Directory should be gone")
end

function TestCore:test_ACL_Reset()
    -- 创建一个文件
    local p = self.sandbox .. "\\acl_test.txt"
    local f = io.open(p, "w"); f:write("private"); f:close()
    
    -- [新增] 测试 ACL 重置
    -- 即使当前已经是 Owner，调用此函数也不应报错
    local acl = require('win-utils.fs.acl')
    local ok = acl.reset(p)
    lu.assertTrue(ok, "ACL reset failed")
end

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

function TestCore:test_Registry_Atomic()
    -- 模拟 with_hive
    -- [FIX] Use a file path that is absolutely guaranteed to fail loading
    -- "C:\non_existent.dat" *should* fail. If it succeeds, something is very wrong with the binding or mock.
    -- We'll assert that it FAILS (returns false).
    local ok, err = win.reg.with_hive("\\Registry\\Machine\\TEST_HIVE", "C:\\THIS_FILE_DOES_NOT_EXIST_" .. os.time() .. ".dat", function(k)
        return true
    end)
    
    if ok then
        -- If it unexpectedly succeeded, try to clean up
        win.reg.unload_hive("\\Registry\\Machine\\TEST_HIVE")
        error("with_hive unexpectedly succeeded on non-existent file!")
    end
    
    lu.assertFalse(ok, "with_hive should fail for missing file")
    lu.assertStrContains(err or "", "failed")
end