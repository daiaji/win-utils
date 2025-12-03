local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

print("[DEBUG] core_spec loaded. win-utils available.")

TestCore = {}

function TestCore:setUp()
    -- 1. 准备沙盒目录
    self.test_dir = "test_sandbox_" .. os.time()
    local k32 = ffi.load("kernel32")
    k32.CreateDirectoryW(require('win-utils.util').to_wide(self.test_dir), nil)
    
    -- 2. 准备注册表沙盒
    self.reg_key = "Software\\LuaWinUtilsTest"
    -- 确保环境干净
    if win.registry then win.registry.delete_key("HKCU", self.reg_key, true) end
end

function TestCore:tearDown()
    -- 清理文件
    if win.fs then win.fs.delete(self.test_dir) end
    if win.fs then win.fs.delete("test.lnk") end
    
    -- 清理注册表
    if win.registry then win.registry.delete_key("HKCU", self.reg_key, true) end
    
    -- 清理热键
    if win.hotkey then win.hotkey.clear() end
end

-- ========================================================================
-- 架构与基础测试
-- ========================================================================
function TestCore:test_LazyLoading()
    lu.assertNotIsNil(win.util, "Util should be preloaded")
    -- 验证子模块 (现在是 Eager Load，只要不为 nil 即可)
    local fs = win.fs
    lu.assertIsTable(fs, "FS module should be loaded")
    lu.assertIsFunction(fs.copy, "FS copy function missing")
end

function TestCore:test_HandleRAII()
    -- 验证自动关闭句柄机制
    local closed = false
    local mock_close = function(h) closed = true end
    local h = win.handle.new(ffi.cast("void*", 0x1234), mock_close)
    
    lu.assertTrue(h:is_valid())
    h:close()
    lu.assertFalse(h:is_valid())
    lu.assertTrue(closed, "Closer function was not called")
end

-- ========================================================================
-- 文件系统 (FS) 测试
-- ========================================================================
function TestCore:test_FS_BasicOps()
    local src = self.test_dir .. "\\src.txt"
    local dst = self.test_dir .. "\\dst.txt"
    local moved = self.test_dir .. "\\moved.txt"
    
    -- Create
    local f = io.open(src, "w"); f:write("test"); f:close()
    
    -- Copy
    lu.assertTrue(win.fs.copy(src, dst), "Copy failed")
    local f2 = io.open(dst, "r"); lu.assertNotIsNil(f2, "Target missing"); f2:close()
    
    -- Move (补回)
    lu.assertTrue(win.fs.move(dst, moved), "Move failed")
    local f3 = io.open(dst, "r"); lu.assertNil(f3, "Source should be gone")
    local f4 = io.open(moved, "r"); lu.assertNotIsNil(f4, "Moved file missing"); f4:close()
    
    -- Native Force Delete
    lu.assertTrue(win.fs.native.force_delete(moved), "Force delete failed")
    local f5 = io.open(moved, "r"); lu.assertNil(f5)
end

function TestCore:test_FS_Recycle()
    -- (补回) 测试回收站 API
    local trash = self.test_dir .. "\\trash.txt"
    local f = io.open(trash, "w"); f:write("junk"); f:close()
    
    lu.assertTrue(win.fs.recycle(trash), "Recycle failed")
    local f2 = io.open(trash, "r")
    lu.assertNil(f2, "File not moved to recycle bin")
end

function TestCore:test_FS_Version()
    -- (补回) 获取系统 DLL 版本
    local ver = win.fs.get_version("C:\\Windows\\System32\\kernel32.dll")
    if not ver then 
        -- CI 环境可能是 Wow64
        ver = win.fs.get_version("C:\\Windows\\SysWOW64\\kernel32.dll") 
    end
    
    if ver then
        lu.assertStrMatches(ver, "%d+%.%d+%.%d+%.%d+")
    else
        print("Skipping version test: kernel32.dll not accessible")
    end
end

-- ========================================================================
-- 注册表 (Registry) 测试
-- ========================================================================
function TestCore:test_Registry_FullTypes()
    -- 确保键存在
    local adv = ffi.load("advapi32")
    local hk = ffi.new("void*[1]")
    adv.RegCreateKeyExW(ffi.cast("void*", 0x80000001), require('win-utils.util').to_wide(self.reg_key), 0, nil, 0, 0xF003F, nil, hk, nil)
    adv.RegCloseKey(hk[0])
    
    local key = win.registry.open_key("HKCU", self.reg_key)
    lu.assertNotIsNil(key)
    
    -- String
    key:write("Str", "LuaJIT")
    lu.assertEquals(key:read("Str"), "LuaJIT")
    
    -- Dword
    key:write("Num", 123456)
    lu.assertEquals(key:read("Num"), 123456)
    
    -- Binary (补回)
    local bin_data = string.char(0xDE, 0xAD, 0xBE, 0xEF)
    key:write("Bin", bin_data, "binary")
    lu.assertEquals(key:read("Bin"), bin_data)
    
    -- Multi_SZ
    local multi = {"Line1", "Line2"}
    key:write("Multi", multi, "multi_sz")
    local read_m = key:read("Multi")
    lu.assertEquals(read_m[1], "Line1")
    lu.assertEquals(read_m[2], "Line2")
    
    key:close()
end

-- ========================================================================
-- 磁盘 (Disk) 测试
-- ========================================================================
function TestCore:test_Disk_ListAndInfo()
    print("[TEST] calling win.disk.list_drives()...")
    if not win.disk.list_drives then
        print("[TEST] ERROR: win.disk.list_drives is nil!")
        -- Fallback check
        if win.disk.info and win.disk.info.list_physical_drives then
             print("[TEST] BUT win.disk.info.list_physical_drives exists.")
        end
    end

    local drives = win.disk.list_drives() -- 原 list() 现为 list_physical_drives
    
    -- 如果是在 CI 的无头/无磁盘环境，drives 可能为空，但不能崩溃
    lu.assertIsTable(drives)
    print(string.format("[TEST] Found %d physical drives.", #drives))
    
    if #drives > 0 then
        lu.assertIsNumber(drives[1].index)
        lu.assertIsString(drives[1].model)
    end
    
    -- 逻辑卷测试
    local vols = win.disk.volume.list()
    lu.assertIsTable(vols)
    if #vols > 0 then
        lu.assertIsString(vols[1].guid_path)
    end
    
    -- (补回) 详细信息测试 (针对 C:)
    local c_info = win.disk.volume.get_info("C:")
    if c_info then
        lu.assertIsString(c_info.filesystem) -- NTFS?
        lu.assertIsNumber(c_info.capacity_mb)
        lu.assertTrue(c_info.capacity_mb > 0)
    end
end

-- ========================================================================
-- 系统杂项 (Shortcut, Hotkey, Shell)
-- ========================================================================
function TestCore:test_Shortcut()
    local target = "C:\\Windows\\System32\\notepad.exe"
    -- 需要绝对路径
    local k32 = ffi.load("kernel32")
    local buf = ffi.new("wchar_t[260]")
    k32.GetFullPathNameW(require('win-utils.util').to_wide(self.test_dir .. "\\test.lnk"), 260, buf, nil)
    local lnk_path = require('win-utils.util').from_wide(buf)
    
    local ok = win.shortcut.create({ path = lnk_path, target = target, desc = "Test" })
    lu.assertTrue(ok, "Create shortcut failed")
    
    local f = io.open(lnk_path, "rb")
    lu.assertNotIsNil(f, "LNK file not created")
    if f then f:close() end
end

function TestCore:test_Hotkey()
    -- (补回) 热键注册测试
    -- 注意：在 CI 无头模式下可能失败，做容错处理
    local id = win.hotkey.register("Ctrl+Alt", "P", function() end)
    if id then
        lu.assertIsNumber(id)
        lu.assertTrue(win.hotkey.unregister(id))
    else
        print("Skipping hotkey test (RegisterHotKey failed, likely headless env)")
    end
end

function TestCore:test_Shell_Argv()
    local t = win.shell.commandline_to_argv('"C:\\Dir With Space\\app.exe" /s')
    lu.assertEquals(#t, 2)
    lu.assertEquals(t[1], "C:\\Dir With Space\\app.exe")
    lu.assertEquals(t[2], "/s")
end