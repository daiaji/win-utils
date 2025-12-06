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

function TestCore:test_Registry_Full()
    local k = win.reg.open_key("HKCU", self.reg_key)
    lu.assertNotNil(k, "Failed to create/open key")
    
    -- 1. String & ExpandSZ
    lu.assertTrue(k:write("TestStr", "Hello World"))
    lu.assertEquals(k:read("TestStr"), "Hello World")
    
    lu.assertTrue(k:write("TestExpand", "%PATH%", "expand_sz"))
    local expanded = k:read("TestExpand")
    lu.assertNotEquals(expanded, "%PATH%")
    
    -- 2. Numbers
    lu.assertTrue(k:write("TestDword", 123456))
    lu.assertEquals(k:read("TestDword"), 123456)
    
    lu.assertTrue(k:write("TestQword", 0x1234567890ULL, "qword"))
    local q = k:read("TestQword")
    lu.assertEquals(tonumber(q), tonumber(0x1234567890ULL))
    
    -- 3. MultiSZ
    local multi = {"Line1", "Line2", "Line 3"}
    lu.assertTrue(k:write("TestMulti", multi, "multi_sz"))
    local m = k:read("TestMulti")
    lu.assertIsTable(m)
    lu.assertEquals(#m, 3)
    lu.assertEquals(m[2], "Line2")
    
    -- 4. Binary
    local bin = ffi.new("uint8_t[3]", {0xAA, 0xBB, 0xCC})
    local str_bin = ffi.string(bin, 3)
    lu.assertTrue(k:write("TestBin", str_bin, "binary"))
    local r_bin = k:read("TestBin")
    lu.assertEquals(#r_bin, 3)
    lu.assertEquals(string.byte(r_bin, 2), 0xBB)
    
    -- 5. Delete
    lu.assertTrue(k:delete_value("TestStr"))
    lu.assertNil(k:read("TestStr"))
    
    k:close()
end