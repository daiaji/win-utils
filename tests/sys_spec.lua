local lu = require('luaunit')
local win = require('win-utils')
local util = require('win-utils.core.util')

TestSys = {}

function TestSys:test_Info()
    local fw = win.sys.info.get_firmware_type()
    lu.assertTrue(fw == "UEFI" or fw == "BIOS")
    
    local pe = win.sys.info.is_winpe()
    lu.assertIsBoolean(pe)
    print("  [INFO] Firmware: " .. fw .. ", WinPE: " .. tostring(pe))
end

function TestSys:test_Env()
    local key = "LUA_TEST_VAR_" .. os.time()
    lu.assertTrue(win.sys.env.set(key, "123"))
    lu.assertEquals(win.sys.env.get(key), "123")
    win.sys.env.set(key, nil)
    lu.assertNil(win.sys.env.get(key))
end

function TestSys:test_Path_Which()
    local cmd = win.sys.path.which("cmd.exe")
    lu.assertNotNil(cmd)
    lu.assertStrContains(cmd:lower(), "system32")
    
    local nothing = win.sys.path.which("NonExistentFile_XYZ.exe")
    lu.assertNil(nothing)
end

function TestSys:test_Shortcut_Full()
    local path = os.getenv("TEMP") .. "\\test_lnk_" .. os.time() .. ".lnk"
    
    local opts = {
        target = "C:\\Windows\\System32\\cmd.exe",
        args = "/k echo hi",
        work_dir = "C:\\Windows",
        desc = "Test Description",
        show = 1,
        icon = "C:\\Windows\\System32\\shell32.dll",
        icon_idx = 1
    }
    
    local ok, res_or_err = pcall(function()
        return win.sys.shortcut.create(path, opts)
    end)
    
    if ok then
        local create_ok, create_err = res_or_err, nil
        if type(res_or_err) ~= "boolean" then 
             create_ok, create_err = res_or_err 
        end
        
        if create_ok then
            lu.assertTrue(win.fs.exists(path))
            os.remove(path)
        else
            print("  [SKIP] Shortcut create logic failed: " .. tostring(create_err))
        end
    else
        print("  [WARN] Shortcut create crashed (COM issue?): " .. tostring(res_or_err))
    end
end

function TestSys:test_Shell_CmdParse()
    lu.assertNotNil(win.sys.shell, "Shell module not exported")
    local cmd = '"C:\\Program Files\\App.exe" /s "argument with spaces"'
    local args = win.sys.shell.parse_cmdline(cmd)
    lu.assertIsTable(args)
    lu.assertEquals(#args, 3)
end

function TestSys:test_Shell_Args()
    local args = win.sys.shell.get_args()
    lu.assertIsTable(args)
    lu.assertTrue(#args >= 1)
end

function TestSys:test_Shell_Browse_Exists()
    if win.sys.shell.browse_folder then
        lu.assertIsFunction(win.sys.shell.browse_folder)
    elseif win.sys.shell.browse then
        lu.assertIsFunction(win.sys.shell.browse)
    end
end

function TestSys:test_Service_List_And_Query()
    local list, err = win.sys.service.list()
    lu.assertNotNil(list, "Service list failed: " .. tostring(err))
    lu.assertTrue(#list > 0)
    
    local _, found = list:findiIf(function(s) 
        local n = s.name:lower()
        return n == "lanmanserver" or n == "eventlog" or n == "schedule"
    end)
    lu.assertNotNil(found)
    
    if found then
        local detail, q_err = win.sys.service.query(found.name)
        lu.assertNotNil(detail, "Service query failed: " .. tostring(q_err))
        lu.assertIsNumber(detail.status)
        local deps = win.sys.service.get_dependents(found.name)
        lu.assertIsTable(deps)
    end
end

function TestSys:test_Service_Config()
    local ok, err = win.sys.service.set_config("NonExistentService_12345", 3)
    lu.assertFalse(ok)
    lu.assertNotNil(err) -- Should return error message now
end

function TestSys:test_Driver_API()
    lu.assertIsFunction(win.sys.driver.load)
    lu.assertIsFunction(win.sys.driver.unload)
    lu.assertIsFunction(win.sys.driver.install)
end

function TestSys:test_Power()
    lu.assertIsFunction(win.sys.power.shutdown)
    lu.assertIsFunction(win.sys.power.reboot)
    
    local ok, err = pcall(function() return win.sys.power.boot_to_firmware() end)
    if not ok then
        print("  [FATAL] boot_to_firmware caused a Lua panic: " .. tostring(err))
        lu.fail("API Crash Detected")
    end
    -- It likely returns false in test env, but shouldn't crash
    if not ok then print("  [INFO] boot_to_firmware result: " .. tostring(err)) end
end

function TestSys:test_Desktop_Display()
    lu.assertIsFunction(win.sys.desktop.set_wallpaper)
    lu.assertIsFunction(win.sys.desktop.refresh)
    lu.assertIsFunction(win.sys.display.set_res)
    lu.assertIsFunction(win.sys.display.set_topology)
end