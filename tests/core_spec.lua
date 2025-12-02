local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

-- [Fix] Removing manual package.path manipulation. 
-- Environment should be set up via LUA_PATH in CI/Wrapper script.

TestWinUtilsCore = {}

function TestWinUtilsCore:setUp()
    -- Prepare Sandbox
    self.test_dir = "test_sandbox"
    local k32 = require('ffi.req')('Windows.sdk.kernel32')

    -- Recursive delete helper for setup cleanup
    if win.fs then win.fs.delete(self.test_dir) end

    -- Create fresh dir
    local function to_w(s)
        local len = k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
        local buf = ffi.new("wchar_t[?]", len)
        k32.MultiByteToWideChar(65001, 0, s, -1, buf, len)
        return buf
    end
    k32.CreateDirectoryW(to_w(self.test_dir), nil)

    -- Registry Sandbox
    self.reg_path = "Software\\LuaWinUtilsTest"
    win.registry.delete_key("HKCU", self.reg_path, true)

    -- Create Registry Key for testing
    local advapi = require('ffi.req')('Windows.sdk.advapi32')
    local hKey = ffi.new("HKEY[1]")
    advapi.RegCreateKeyExW(ffi.cast("HKEY", 0x80000001), to_w(self.reg_path), 0, nil, 0, 0xF003F, nil, hKey, nil)
    advapi.RegCloseKey(hKey[0])
end

function TestWinUtilsCore:tearDown()
    win.fs.delete(self.test_dir)
    win.fs.delete("test.lnk")
    win.registry.delete_key("HKCU", self.reg_path, true)
end

-- 辅助函数：获取绝对路径
function TestWinUtilsCore:get_abs_path(rel_path)
    local k32 = require('ffi.req')('Windows.sdk.kernel32')
    local util = require('win-utils.util')
    local wrel = util.to_wide(rel_path)
    local len = k32.GetFullPathNameW(wrel, 0, nil, nil)
    if len == 0 then return rel_path end

    local buf = ffi.new("wchar_t[?]", len)
    k32.GetFullPathNameW(wrel, len, buf, nil)
    return util.from_wide(buf)
end

-- ========================================================================
-- FS (File System) Tests
-- ========================================================================
function TestWinUtilsCore:test_fs_lifecycle()
    local file_src = self.test_dir .. "\\src.txt"
    local file_dst = self.test_dir .. "\\dst.txt"
    local file_moved = self.test_dir .. "\\moved.txt"

    -- 1. Create file
    local f = io.open(file_src, "w")
    f:write("hello filesystem")
    f:close()

    -- 2. Copy
    lu.assertTrue(win.fs.copy(file_src, file_dst))

    local f2 = io.open(file_dst, "r")
    lu.assertNotIsNil(f2, "Copy target missing")
    if f2 then f2:close() end

    -- 3. Move
    lu.assertTrue(win.fs.move(file_dst, file_moved))

    local f3 = io.open(file_dst, "r")
    lu.assertIsNil(f3, "Move source should be gone")

    local f4 = io.open(file_moved, "r")
    lu.assertNotIsNil(f4, "Move target missing")
    if f4 then f4:close() end

    -- 4. Delete
    lu.assertTrue(win.fs.delete(file_moved))
    local f5 = io.open(file_moved, "r")
    lu.assertIsNil(f5, "Delete failed")
end

function TestWinUtilsCore:test_fs_recycle()
    local file_trash = self.test_dir .. "\\trash.txt"
    local f = io.open(file_trash, "w")
    f:write("junk")
    f:close()

    -- 尝试回收
    local ok = win.fs.recycle(file_trash)

    if ok then
        local f_check = io.open(file_trash, "r")
        lu.assertIsNil(f_check, "Recycled file should be gone")
    end
end

function TestWinUtilsCore:test_fs_get_version()
    local ver = win.fs.get_version("C:\\Windows\\System32\\kernel32.dll")
    if not ver then
        ver = win.fs.get_version("C:\\Windows\\SysWOW64\\kernel32.dll")
    end

    if ver then
        lu.assertStrMatches(ver, "%d+%.%d+%.%d+%.%d+")
    else
        print("Skipping version test (kernel32 not found or no version info)")
    end
end

-- ========================================================================
-- Registry Tests
-- ========================================================================
function TestWinUtilsCore:test_registry_rw()
    local key = win.registry.open_key("HKCU", self.reg_path)
    lu.assertNotIsNil(key, "Failed to open test registry key")

    lu.assertTrue(key:write("TestStr", "LuaJIT"))
    lu.assertEquals(key:read("TestStr"), "LuaJIT")

    lu.assertTrue(key:write("TestDword", 123456, "dword"))
    lu.assertEquals(key:read("TestDword"), 123456)

    local bin = string.char(0x01, 0x02, 0xFF)
    lu.assertTrue(key:write("TestBin", bin, "binary"))
    lu.assertEquals(key:read("TestBin"), bin)

    local multi = { "Line1", "Line2" }
    lu.assertTrue(key:write("TestMulti", multi, "multi_sz"))
    local read_multi = key:read("TestMulti")
    lu.assertIsTable(read_multi)
    lu.assertEquals(read_multi[1], "Line1")
    lu.assertEquals(read_multi[2], "Line2")

    key:close()
end

-- ========================================================================
-- Disk Tests
-- ========================================================================
function TestWinUtilsCore:test_disk_info()
    local drives = win.disk.list()
    lu.assertIsTable(drives)

    local has_drive = (#drives > 0)
    lu.assertTrue(has_drive, "No logical drives found")

    if has_drive then
        local d = drives[1]
        local info = win.disk.info(d)
        lu.assertNotIsNil(info)
        lu.assertIsString(info.type)
        lu.assertIsNumber(info.capacity_mb)
    end
end

-- ========================================================================
-- Shortcut Tests
-- ========================================================================
function TestWinUtilsCore:test_shortcut()
    local target = "C:\\Windows\\System32\\notepad.exe"
    local lnk_path = self:get_abs_path(self.test_dir .. "\\test.lnk")

    local ok = win.shortcut.create({
        path = lnk_path,
        target = target,
        desc = "Test Link"
    })

    lu.assertTrue(ok, "Shortcut creation returned false")

    local f = io.open(lnk_path, "rb")
    lu.assertNotIsNil(f, "Shortcut file was not created at: " .. lnk_path)
    if f then f:close() end
end

-- ========================================================================
-- Hotkey Tests
-- ========================================================================
function TestWinUtilsCore:test_hotkey_registration()
    local id, err = win.hotkey.register("Ctrl+Alt", "P", function() end)

    if not id then
        print("Skipping hotkey test (RegisterHotKey failed: " .. tostring(err) .. ")")
        return
    end

    lu.assertIsNumber(id)
    lu.assertTrue(win.hotkey.unregister(id))
end

function TestWinUtilsCore:test_hotkey_logic()
    local hit_count = 0
    local cb = function() hit_count = hit_count + 1 end

    -- VK_F12 = 0x7B (123)
    local id = win.hotkey.register("Shift", 123, cb)

    if id then
        win.hotkey.dispatch(id)
        lu.assertEquals(hit_count, 1)

        local err_cb = function() error("Simulated Crash") end
        local id_err = win.hotkey.register("Shift", 122, err_cb)
        if id_err then
            local status = pcall(win.hotkey.dispatch, id_err)
            lu.assertTrue(status, "Dispatch logic should catch callback errors")
            win.hotkey.unregister(id_err)
        end
        win.hotkey.unregister(id)
    end
end

-- ========================================================================
-- Shell Tests
-- ========================================================================
function TestWinUtilsCore:test_shell_argv_parsing()
    local t1 = win.shell.commandline_to_argv('exe a b')
    lu.assertEquals(#t1, 3)
    lu.assertEquals(t1[2], 'a')

    local t2 = win.shell.commandline_to_argv('"C:\\Path With Spaces\\exe" "arg 1"')
    lu.assertEquals(t2[1], 'C:\\Path With Spaces\\exe')
    lu.assertEquals(t2[2], 'arg 1')

    local t3 = win.shell.commandline_to_argv('exe "测试"')
    lu.assertEquals(t3[2], '测试')
end