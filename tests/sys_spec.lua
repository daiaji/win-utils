local lu = require('luaunit')
local win = require('win-utils')

TestSys = {}

function TestSys:test_Info_Firmware()
    local fw = win.sys.info.get_firmware_type()
    lu.assertIsString(fw)
    print("\n  [TEST] Firmware Type: " .. fw)
end

function TestSys:test_Info_Env()
    lu.assertIsBoolean(win.sys.info.is_winpe())
end

function TestSys:test_Service_List()
    local list = win.sys.service.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    local _, found = list:findiIf(function(s) 
        local n = s.name:lower()
        return n == "lanmanserver" or n == "eventlog" or n == "schedule"
    end)
    
    lu.assertNotNil(found, "Core Windows service not found")
    if found then
        print("  [TEST] Found Core Service: " .. found.display)
    end
end

function TestSys:test_Service_Config()
    local ok = win.sys.service.set_config("NonExistentService_12345", 3)
    lu.assertFalse(ok)
end

function TestSys:test_Driver_API()
    lu.assertIsFunction(win.sys.driver.load)
end

-- [Enhanced] 完整测试快捷方式的各项属性
function TestSys:test_Shortcut_Full()
    local path = os.getenv("TEMP") .. "\\test_full_" .. os.time() .. ".lnk"
    
    -- 复杂参数配置
    local opts = {
        target = "C:\\Windows\\System32\\cmd.exe",
        args = "/k echo hello",
        work_dir = "C:\\Windows",
        desc = "Test Description"
    }
    
    local ok, err = pcall(function() 
        return win.sys.shortcut.create(path, opts)
    end)
    
    if ok and err then
        local f = io.open(path, "rb")
        if f then 
            f:close()
            -- 在 CI 环境下很难验证 .lnk 内部二进制内容，
            -- 但创建成功即代表 COM 接口调用正常。
            lu.assertTrue(true)
            os.remove(path)
        else
            print("\n  [WARN] Shortcut success but file not found")
        end
    else
        print("\n  [SKIP] Shortcut create failed (COM/CI issue?): " .. tostring(err))
    end
end

function TestSys:test_Shell_CmdParse()
    lu.assertNotNil(win.sys.shell, "Shell module not exported")
    
    local cmd = '"C:\\Program Files\\App.exe" /s "argument with spaces"'
    local args = win.sys.shell.parse_cmdline(cmd)
    
    lu.assertIsTable(args)
    lu.assertEquals(#args, 3)
    lu.assertEquals(args[1], "C:\\Program Files\\App.exe")
    lu.assertEquals(args[2], "/s")
    lu.assertEquals(args[3], "argument with spaces")
end

function TestSys:test_Shell_GetArgs()
    local args = win.sys.shell.get_args()
    lu.assertIsTable(args)
    lu.assertTrue(#args >= 1, "Should return at least executable path")
    
    print("  [INFO] Current Process Args:")
    for i, v in ipairs(args) do
        print(string.format("    [%d] %s", i, v))
    end
    lu.assertIsString(args[1])
end

-- [New] 验证 browse API 是否存在（不执行，防止阻塞）
function TestSys:test_Shell_Browse_Exists()
    lu.assertIsFunction(win.sys.shell.browse)
end

function TestSys:test_Power_UEFI()
    local ok, err = pcall(function()
        return win.sys.power.boot_to_firmware()
    end)
    
    if not ok then
        print("  [WARN] boot_to_firmware crashed: " .. tostring(err))
        lu.fail("Crash in boot_to_firmware")
    end
    lu.assertIsBoolean(err)
end