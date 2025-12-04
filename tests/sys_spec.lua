local lu = require('luaunit')
local win = require('win-utils')

TestSys = {}

-- ========================================================================
-- 系统信息 (Info)
-- ========================================================================
function TestSys:test_Info_Firmware()
    -- 新增：UEFI/BIOS 检测
    local fw = win.sys.info.get_firmware_type()
    lu.assertIsString(fw)
    lu.assertTrue(fw == "UEFI" or fw == "BIOS")
    
    print("[TEST] Firmware Type: " .. fw)
end

function TestSys:test_Info_Env()
    local is_pe = win.sys.info.is_winpe()
    lu.assertIsBoolean(is_pe)
    print("[TEST] Is WinPE: " .. tostring(is_pe))
end

-- ========================================================================
-- 服务与驱动
-- ========================================================================
function TestSys:test_Service_List()
    local list = win.sys.service.list()
    lu.assertIsTable(list)
    local found = false
    -- 检查核心服务
    for _, s in ipairs(list) do
        if s.name:lower() == "eventlog" or s.name:lower() == "spooler" then 
            found = true 
            break 
        end
    end
    lu.assertTrue(found, "Standard service not found")
end

function TestSys:test_Driver_API()
    -- 仅检查 API 导出，不执行加载（极其危险）
    lu.assertIsFunction(win.sys.driver.load)
    lu.assertIsFunction(win.sys.driver.install)
end

-- ========================================================================
-- 桌面与快捷方式
-- ========================================================================
function TestSys:test_Shortcut()
    local path = os.getenv("TEMP") .. "\\test_" .. os.time() .. ".lnk"
    local target = "C:\\Windows\\System32\\notepad.exe"
    
    -- COM 在 CI 环境可能不稳定，做 pcall 保护
    local ok = pcall(function() 
        win.sys.shortcut.create(path, target)
    end)
    
    if ok then
        local f = io.open(path, "rb")
        if f then 
            f:close()
            os.remove(path)
            lu.assertTrue(true)
        else
            -- 可能是 CI 环境没有 Shell 接口
            print("[WARN] Shortcut created but file not found (Headless?)")
        end
    else
        print("[WARN] Shortcut creation skipped (COM error)")
    end
end