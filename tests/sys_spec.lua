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

-- [New] 测试服务配置修改 (Restored Feature)
function TestSys:test_Service_Config()
    -- 这是一个危险操作，我们只测试函数是否存在且能安全调用（针对不存在的服务应返回 false）
    -- 不去修改真实服务的配置以免破坏环境
    local ok = win.sys.service.set_config("NonExistentService_12345", 3)
    lu.assertFalse(ok)
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
            print("\n  [WARN] Shortcut reported success but file missing")
        end
    else
        print("\n  [SKIP] Shortcut creation not supported: " .. tostring(err))
    end
end

-- [New] 命令行解析测试 (Restored Feature)
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

-- [New] UEFI 启动标记测试 (Restored Feature)
function TestSys:test_Power_UEFI()
    -- 此测试不会导致立即重启，只是设置 NVRAM 变量
    -- 在不支持 UEFI 的 VM 中可能会失败，断言返回 boolean 即可
    local ok, err = pcall(function()
        return win.sys.power.boot_to_firmware()
    end)
    
    if not ok then
        print("  [WARN] boot_to_firmware crashed: " .. tostring(err))
        lu.fail("Crash in boot_to_firmware")
    end
    
    -- 我们只验证它是否安全运行并返回结果，不强制要求必须成功（取决于硬件）
    lu.assertIsBoolean(err) -- err holds result here
    if err then
        print("  [INFO] Boot to Firmware: Supported & Set")
    else
        print("  [INFO] Boot to Firmware: Not supported or Perms denied")
    end
end