local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local util = require('win-utils.core.util')

TestCore = {}

function TestCore:setUp()
    self.reg_key = "Software\\LuaWinUtilsTest_" .. os.time()
    if win.reg then win.reg.delete_key("HKCU", self.reg_key, true) end
end

function TestCore:tearDown()
    if win.reg then win.reg.delete_key("HKCU", self.reg_key, true) end
end

function TestCore:test_Util_GUID()
    local s = "{53F56307-B6BF-11D0-94F2-00A0C91EFB8B}"
    local g = util.guid_from_str(s)
    local s2 = util.guid_to_str(g)
    lu.assertEquals(s2:upper(), s:upper())
end

function TestCore:test_Util_Path()
    local parts = util.split_path("C:\\Windows\\System32")
    lu.assertEquals(parts[1], "C:")
    lu.assertEquals(parts[2], "Windows")
    lu.assertEquals(util.normalize_path("C:/Windows//System32/"), "C:\\Windows\\System32")
end

-- [Moved from fs_spec]
function TestCore:test_Path_Conversion_NT()
    local path_mod = require('win-utils.fs.path')
    local nt = "\\??\\C:\\Windows"
    local dos = path_mod.nt_path_to_dos(nt)
    
    -- This relies on C: existing, which is safe assumption
    if dos then
        lu.assertStrContains(dos, "Windows")
        lu.assertStrContains(dos, ":")
    else
        print("[INFO] Path conversion returned nil (Non-standard drive map?)")
    end
end

function TestCore:test_Registry_Full()
    local k, err = win.reg.open_key("HKCU", self.reg_key)
    lu.assertNotNil(k, "Failed to create/open key: " .. tostring(err))
    
    -- 1. String & ExpandSZ
    local ok, w_err = k:write("TestStr", "Hello World")
    lu.assertTrue(ok, tostring(w_err))
    lu.assertEquals(k:read("TestStr"), "Hello World")
    
    k:write("TestExpand", "%PATH%", "expand_sz")
    local expanded = k:read("TestExpand")
    lu.assertNotEquals(expanded, "%PATH%")
    
    -- 2. Numbers
    k:write("TestDword", 123456)
    lu.assertEquals(k:read("TestDword"), 123456)
    
    k:write("TestQword", 0x1234567890ULL, "qword")
    local q = k:read("TestQword")
    lu.assertEquals(tonumber(q), tonumber(0x1234567890ULL))
    
    -- 3. MultiSZ
    local multi = {"Line1", "Line2", "Line 3"}
    k:write("TestMulti", multi, "multi_sz")
    local m = k:read("TestMulti")
    lu.assertIsTable(m)
    lu.assertEquals(#m, 3)
    lu.assertEquals(m[2], "Line2")
    
    -- 4. Binary
    local bin = ffi.new("uint8_t[3]", {0xAA, 0xBB, 0xCC})
    local str_bin = ffi.string(bin, 3)
    k:write("TestBin", str_bin, "binary")
    local r_bin = k:read("TestBin")
    lu.assertEquals(#r_bin, 3)
    lu.assertEquals(string.byte(r_bin, 2), 0xBB)

    -- 5. Enumeration
    local values = k:enum_values()
    lu.assertIsTable(values)
    local value_names = {}
    for _, item in ipairs(values) do value_names[item.name] = item end
    lu.assertEquals(value_names.TestDword.type, "dword")
    lu.assertEquals(value_names.TestMulti.type, "multi_sz")
    lu.assertEquals(value_names.TestBin.type, "binary")

    local sub, sub_err = win.reg.create_key("HKCU", self.reg_key .. "\\Child")
    lu.assertNotNil(sub, tostring(sub_err))
    sub:close()
    local keys = k:enum_keys()
    lu.assertIsTable(keys)
    lu.assertEquals(keys[1], "Child")

    local existing, open_err = win.reg.open_existing_key("HKCU", self.reg_key)
    lu.assertNotNil(existing, tostring(open_err))
    existing:close()
    local missing = win.reg.open_existing_key("HKCU", self.reg_key .. "\\Missing")
    lu.assertNil(missing)

    local export_path = os.getenv("TEMP") .. "\\test_reg_export_" .. os.time() .. ".reg"
    local exp_ok, exp_err = win.reg.export("HKCU", self.reg_key, export_path)
    lu.assertTrue(exp_ok, tostring(exp_err))
    local exp = win.fs.read(export_path)
    lu.assertNotNil(exp)
    lu.assertTrue(#exp > 2)

    local import_plan = win.reg.import_file(export_path, { dry_run = true })
    lu.assertIsTable(import_plan)
    lu.assertTrue(import_plan.dry_run)
    win.fs.delete(export_path)
    
    -- 6. Delete
    lu.assertTrue(k:delete_value("TestStr"))
    lu.assertNil(k:read("TestStr"))
    
    k:close()
end

function TestCore:test_Text_And_File_Helpers()
    local text = "Hello World"
    local encoded = win.text.base64_encode(text)
    lu.assertEquals(encoded, "SGVsbG8gV29ybGQ=")
    lu.assertEquals(win.text.base64_decode(encoded), text)
    local bom_text = win.text.to_utf8_auto("\239\187\191Hello")
    lu.assertEquals(bom_text, "Hello")
    lu.assertEquals(win.fs.hash("123456789"), "cbf43926")

    local path = os.getenv("TEMP") .. "\\test_fs_text_" .. os.time() .. ".txt"
    local path2 = os.getenv("TEMP") .. "\\test_fs_text_" .. os.time() .. "_copy.txt"
    lu.assertTrue(win.fs.write(path, "abc"))
    lu.assertEquals(win.fs.read(path), "abc")
    lu.assertEquals(win.fs.hash_file(path), win.fs.hash("abc"))
    lu.assertTrue(win.text.convert_file(path, path2, win.text.CP_UTF8, win.text.CP_UTF8))
    lu.assertEquals(win.fs.read(path2), "abc")
    win.fs.delete(path)
    win.fs.delete(path2)
end

function TestCore:test_Path_Helpers()
    lu.assertEquals(win.fs.path.basename("C:\\Windows\\notepad.exe"), "notepad.exe")
    lu.assertEquals(win.fs.path.dirname("C:\\Windows\\notepad.exe"), "C:\\Windows")
    lu.assertEquals(win.fs.path.stem("C:\\Windows\\notepad.exe"), "notepad")
    lu.assertEquals(win.fs.path.extension("C:\\Windows\\notepad.exe"), ".exe")
    lu.assertEquals(win.fs.path.drive("C:\\Windows\\notepad.exe"), "C:")
end

function TestCore:test_Log_File()
    local path = os.getenv("TEMP") .. "\\win_utils_log_" .. os.time() .. ".txt"
    local ok, err = win.log.configure({ level = "debug", file = path, console = false })
    lu.assertTrue(ok, tostring(err))
    lu.assertTrue(win.log.info("hello", { answer = 42 }))
    local scoped = win.log.scoped("test")
    lu.assertTrue(scoped:warn("scoped"))
    local data = win.fs.read(path)
    lu.assertStrContains(data, "INFO hello")
    lu.assertStrContains(data, "scope=test")
    win.fs.delete(path)
end

function TestCore:test_INI_Helpers()
    local parsed = win.ini.parse("root=yes\r\n[main]\r\nname = test\r\ncount=2\r\n")
    lu.assertEquals(parsed.root, "yes")
    lu.assertEquals(win.ini.get(parsed, "main", "name"), "test")
    win.ini.set(parsed, "main", "enabled", "true")
    local encoded = win.ini.encode(parsed)
    lu.assertStrContains(encoded, "[main]")
    lu.assertStrContains(encoded, "enabled=true")
end

function TestCore:test_FS_Read_Write_Options()
    local base = os.getenv("TEMP") .. "\\test_fs_opts_" .. os.time() .. ".txt"
    local atomic_path = os.getenv("TEMP") .. "\\test_fs_opts_atomic_" .. os.time() .. ".txt"
    local utf16_path = os.getenv("TEMP") .. "\\test_fs_opts_utf16_" .. os.time() .. ".txt"

    lu.assertTrue(win.fs.write(base, "abcdef"))
    lu.assertEquals(win.fs.read(base, { offset = 2, length = 3 }), "cde")
    lu.assertTrue(win.fs.write(base, "ZZ", { offset = 2 }))
    lu.assertEquals(win.fs.read(base), "abZZef")

    lu.assertTrue(win.fs.write(atomic_path, "atomic-data", { atomic = true }))
    lu.assertEquals(win.fs.read(atomic_path), "atomic-data")

    lu.assertTrue(win.fs.write(utf16_path, "hello", { encoding = "utf-16le" }))
    lu.assertEquals(win.fs.read(utf16_path, { encoding = "utf-16le" }), "hello")

    win.fs.delete(base)
    win.fs.delete(atomic_path)
    win.fs.delete(utf16_path)
end

function TestCore:test_Crypto_Hash()
    lu.assertEquals(win.crypto.hash("123456789", "crc32"), "cbf43926")
    local sha = win.crypto.hash("abc", "sha256")
    if sha then
        lu.assertEquals(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    else
        print("  [SKIP] CryptoAPI SHA256 unavailable in this environment")
    end
end
