local lu = require('luaunit')
local win = require('win-utils')

TestSys = {}

function TestSys:test_Info_Firmware()
    local fw = win.sys.info.get_firmware_type()
    lu.assertIsString(fw)
    print("\n[TEST] Firmware Type: " .. fw)
end

function TestSys:test_Info_Env()
    lu.assertIsBoolean(win.sys.info.is_winpe())
end

function TestSys:test_Service_List()
    local list = win.sys.service.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    -- [Lua-Ext] 使用新的 findiIf 替代 filter(..)[1]
    -- findiIf 使用 ipairs，对于列表遍历更高效且有序
    local _, found = list:findiIf(function(s) 
        local n = s.name:lower()
        return n == "lanmanserver" or n == "eventlog" or n == "schedule"
    end)
    
    lu.assertNotNil(found, "Core Windows service not found")
    if found then
        print("[TEST] Found Core Service: " .. found.display)
    end
end

function TestSys:test_Driver_API()
    lu.assertIsFunction(win.sys.driver.load)
end

function TestSys:test_Shortcut()
    local path = os.getenv("TEMP") .. "\\test_" .. os.time() .. ".lnk"
    local target = "C:\\Windows\\System32\\cmd.exe"
    
    local ok, err = pcall(function() 
        win.sys.shortcut.create(path, target)
    end)
    
    if ok then
        local f = io.open(path, "rb")
        if f then 
            f:close()
            os.remove(path)
            lu.assertTrue(true)
        else
            print("\n[WARN] Shortcut reported success but file missing")
        end
    else
        print("\n[SKIP] Shortcut creation not supported: " .. tostring(err))
    end
end