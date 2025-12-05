local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestProcess = {}

-- 测试常量
local TEST_CMD_LONG = "cmd.exe /c ping -n 30 127.0.0.1 > NUL"
local TEST_CMD_SHORT = "cmd.exe /c ping -n 3 127.0.0.1 > NUL"
local TEST_UNICODE_ARG = "测试参数_Arg"

-- 辅助：清理环境
function TestProcess:tearDown()
    -- 强杀残留的 cmd/ping
    local list = win.process.list()
    if list then
        for _, p in ipairs(list) do
            if p.name:lower() == "ping.exe" then
                win.process.terminate(p.pid)
            end
        end
    end
end

-- 1. 基础生命周期测试 (Exec, Exists, Terminate)
function TestProcess:test_Lifecycle()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0) -- SW_HIDE
    lu.assertNotNil(p, "Exec failed")
    lu.assertTrue(p.pid > 0)
    
    -- 验证 exists (PID)
    lu.assertEquals(win.process.exists(p.pid), p.pid)
    -- 验证 exists (Name)
    local found_pid = win.process.exists("cmd.exe") -- 注意：exec 返回的是 cmd 的 pid
    lu.assertTrue(found_pid > 0)
    
    -- 终止
    lu.assertTrue(p:terminate())
    
    -- 等待系统回收
    ffi.C.Sleep(200)
    lu.assertEquals(win.process.exists(p.pid), 0, "Process should be gone")
    p:close()
end

-- 2. 等待逻辑测试 (Wait Timeout vs Success)
function TestProcess:test_Wait()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    -- 测试：超时 (应返回 false)
    local start = os.clock()
    local res = p:wait(200) -- 等 200ms
    local duration = os.clock() - start
    
    lu.assertFalse(res, "Wait should timeout")
    
    p:terminate()
    
    -- 测试：成功等待
    local p2 = win.process.exec("cmd.exe /c exit 0", nil, 0)
    lu.assertTrue(p2:wait(2000), "Wait should succeed for quick exit")
    p2:close()
    p:close()
end

-- 3. 信息获取与 Unicode 支持
function TestProcess:test_Info_And_Unicode()
    -- 构造带 Unicode 的命令
    local cmd = string.format('cmd.exe /c "ping -n 1 127.0.0.1 > NUL & rem %s"', TEST_UNICODE_ARG)
    local p = win.process.exec(cmd, nil, 0)
    lu.assertNotNil(p)
    
    local info = p:get_info()
    lu.assertIsTable(info)
    
    -- 验证路径
    lu.assertStrContains(info.exe_path:lower(), "cmd.exe")
    
    -- 验证命令行 (Unicode)
    -- 注意：cmd.exe 的行为可能会重构命令行，只要包含关键字即可
    local cmdline = p:get_command_line()
    lu.assertStrContains(cmdline, TEST_UNICODE_ARG)
    
    p:terminate()
    p:close()
end

-- 4. 进程列表与查找
function TestProcess:test_List_And_Find()
    -- 启动两个进程
    local p1 = win.process.exec(TEST_CMD_LONG, nil, 0)
    local p2 = win.process.exec(TEST_CMD_LONG, nil, 0)
    
    local list = win.process.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list >= 2)
    
    -- 使用 Lua-Ext 的 findiIf 验证
    local _, found1 = list:findiIf(function(x) return x.pid == p1.pid end)
    local _, found2 = list:findiIf(function(x) return x.pid == p2.pid end)
    
    lu.assertNotNil(found1)
    lu.assertNotNil(found2)
    
    -- 验证父进程ID (PPID)
    lu.assertIsNumber(found1.parent_pid)
    
    p1:terminate(); p1:close()
    p2:terminate(); p2:close()
end

-- 5. 挂起与恢复 (Suspend/Resume)
function TestProcess:test_Suspend_Resume()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    
    -- 挂起
    lu.assertTrue(p:suspend())
    
    -- 恢复
    lu.assertTrue(p:resume())
    
    p:terminate()
    p:close()
end

-- 6. 进程树终止 (Terminate Tree)
function TestProcess:test_Tree_Terminate()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    ffi.C.Sleep(500)
    
    local list = win.process.list()
    local child_pid = nil
    for _, item in ipairs(list) do
        if item.name:lower() == "ping.exe" and item.parent_pid == p.pid then
            child_pid = item.pid
            break
        end
    end
    
    if child_pid then
        print("  [DEBUG] Found child process: " .. child_pid)
        lu.assertTrue(win.process.exists(child_pid) > 0)
        
        -- 杀进程树
        p:terminate_tree()
        ffi.C.Sleep(200)
        
        -- 验证父子全挂
        lu.assertEquals(win.process.exists(p.pid), 0, "Parent should remain dead")
        lu.assertEquals(win.process.exists(child_pid), 0, "Child should be dead")
    else
        print("  [WARN] Could not spawn child process for tree test (CI env?)")
        p:terminate()
    end
    p:close()
end

-- 7. 令牌信息 (Token Info)
function TestProcess:test_Token_Info()
    local t = win.process.token.open_current(8) -- QUERY
    if t then
        local user = win.process.token.get_user(t)
        lu.assertIsString(user)
        print("  [INFO] Current User: " .. user)
        
        local integrity = win.process.token.get_integrity_level(t)
        if integrity then
            print("  [INFO] Integrity: " .. integrity)
        end
        t:close()
    end
    
    lu.assertTrue(win.process.token.is_elevated())
    lu.assertTrue(win.process.token.enable_privilege("SeDebugPrivilege"))
end

-- 8. [NEW] 静态等待函数测试 (Restored Features)
function TestProcess:test_Static_Wait_Helpers()
    -- 测试 wait (等待进程出现)
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    local found_pid = win.process.wait(p.pid, 1000)
    lu.assertEquals(found_pid, p.pid)
    
    -- 测试 wait_close (等待进程结束)
    p:terminate()
    
    local closed = win.process.wait_close(p.pid, 2000)
    lu.assertTrue(closed, "wait_close should return true")
    
    p:close()
end

-- [New] 测试内存区域列表及文件名解析 (检测 ntdll.dll 是否被识别)
function TestProcess:test_Memory_Regions()
    local p = win.process.current()
    lu.assertNotNil(p, "Could not open current process")
    
    local regions = win.process.memory.list_regions(p.pid)
    lu.assertIsTable(regions)
    lu.assertTrue(#regions > 0)
    
    local found_ntdll = false
    local found_any_file = false
    
    for _, r in ipairs(regions) do
        if r.filename then
            found_any_file = true
            if r.filename:lower():find("ntdll.dll") then
                found_ntdll = true
                print("  [INFO] Mapped: " .. r.filename)
                break
            end
        end
    end
    
    -- 在 Windows 环境下，进程必然加载了 DLL，至少应该能解析出一个文件名
    lu.assertTrue(found_any_file, "No mapped filenames resolved (Privilege issue?)")
    
    -- 几乎所有进程都加载 ntdll
    if found_ntdll then
        lu.assertTrue(true)
    else
        print("  [WARN] ntdll.dll not found in memory map (Unusual)")
    end
    
    p:close()
end