local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestProcess = {}

-- 测试常量
local TEST_CMD_LONG = "cmd.exe /c ping -n 30 127.0.0.1 > NUL"
local TEST_UNICODE_ARG = "测试参数_Arg_🚀"

-- 辅助：清理环境
function TestProcess:tearDown()
    -- 强杀残留的 cmd/ping
    local list = win.process.list()
    if list then
        for _, p in ipairs(list) do
            if p.name:lower() == "ping.exe" then
                win.process.kill(p.pid)
            end
        end
    end
end

-- 1. 基础生命周期测试 (Exec, Exists, Kill)
function TestProcess:test_Lifecycle()
    local p, err = win.process.exec(TEST_CMD_LONG, nil, 0) -- SW_HIDE
    lu.assertNotNil(p, "Exec failed: " .. tostring(err))
    lu.assertTrue(p.pid > 0)
    
    lu.assertEquals(win.process.exists(p.pid), p.pid)
    
    local found_pid = win.process.exists("cmd.exe")
    lu.assertTrue(found_pid > 0)
    
    local k_ok, k_err = p:kill()
    lu.assertTrue(k_ok, "Kill failed: " .. tostring(k_err))
    
    ffi.C.Sleep(200)
    lu.assertEquals(win.process.exists(p.pid), 0, "Process should be gone")
    p:close()
end

-- 2. 等待逻辑测试 (Wait Timeout vs Success)
function TestProcess:test_Wait()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    local start = os.clock()
    local res = p:wait(200) -- 等 200ms
    
    lu.assertFalse(res, "Wait should timeout")
    
    p:kill()
    
    local p2 = win.process.exec("cmd.exe /c exit 0", nil, 0)
    lu.assertTrue(p2:wait(2000), "Wait should succeed for quick exit")
    p2:close()
    p:close()
end

-- 3. 信息获取与 Unicode 支持
function TestProcess:test_Info_And_Unicode()
    local cmd = string.format('cmd.exe /c "ping -n 1 127.0.0.1 > NUL & rem %s"', TEST_UNICODE_ARG)
    local p = win.process.exec(cmd, nil, 0)
    lu.assertNotNil(p)
    
    local info = p:get_info()
    lu.assertIsTable(info)
    
    lu.assertStrContains(info.exe_path:lower(), "cmd.exe")
    
    local cmdline = p:get_command_line()
    lu.assertStrContains(cmdline, TEST_UNICODE_ARG)
    
    p:kill()
    p:close()
end

-- 4. 进程列表与查找
function TestProcess:test_List_And_Find()
    local p1 = win.process.exec(TEST_CMD_LONG, nil, 0)
    local p2 = win.process.exec(TEST_CMD_LONG, nil, 0)
    
    local list = win.process.list()
    lu.assertIsTable(list)
    lu.assertTrue(#list >= 2)
    
    local _, found1 = list:findiIf(function(x) return x.pid == p1.pid end)
    local _, found2 = list:findiIf(function(x) return x.pid == p2.pid end)
    
    lu.assertNotNil(found1)
    lu.assertNotNil(found2)
    
    lu.assertIsNumber(found1.parent_pid)
    lu.assertIsString(found1.name)
    
    p1:kill(); p1:close()
    p2:kill(); p2:close()
end

-- 5. 挂起与恢复 (Suspend/Resume)
function TestProcess:test_Suspend_Resume()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    
    lu.assertTrue(p:suspend())
    lu.assertTrue(p:resume())
    
    p:kill()
    p:close()
end

-- 6. 进程树终止 (Kill Tree)
function TestProcess:test_Tree_Kill()
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
        print("  [DEBUG] Found child process for tree kill: " .. child_pid)
        lu.assertTrue(win.process.exists(child_pid) > 0)
        
        p:kill("tree")
        ffi.C.Sleep(200)
        
        lu.assertEquals(win.process.exists(p.pid), 0, "Parent should be dead")
        lu.assertEquals(win.process.exists(child_pid), 0, "Child should be dead")
    else
        print("  [WARN] Could not spawn child process for tree test (CI env?)")
        p:kill()
    end
    p:close()
end

-- 7. [RESTORED] 优先级设置 (Priority)
function TestProcess:test_Priority()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    -- 7.1 Set to IDLE (L)
    local ok_l, err_l = p:set_priority("L")
    lu.assertTrue(ok_l, "Set priority 'L' failed: " .. tostring(err_l))
    
    -- 7.2 Set to NORMAL (N)
    local ok_n, err_n = p:set_priority("N")
    lu.assertTrue(ok_n, "Set priority 'N' failed: " .. tostring(err_n))
    
    -- 7.3 Invalid Priority
    local ok_bad, _ = p:set_priority("INVALID_MODE")
    lu.assertFalse(ok_bad, "Set invalid priority should fail")
    
    p:kill()
    p:close()
end

-- 8. 令牌信息 (Token Info)
function TestProcess:test_Token_Info()
    local t, err = win.process.token.open_current(8) -- QUERY
    lu.assertNotNil(t, "open_current failed: " .. tostring(err))
    
    local user = win.process.token.get_user(t)
    lu.assertIsString(user)
    print("  [INFO] Current User: " .. user)
    
    local integrity = win.process.token.get_integrity_level(t)
    if integrity then
        print("  [INFO] Integrity: " .. integrity)
    end
    t:close()
    
    lu.assertTrue(type(win.process.token.is_elevated()) == "boolean")
    
    if win.process.token.enable_privilege then
        local ok, p_err = win.process.token.enable_privilege("SeDebugPrivilege")
        -- SeDebugPrivilege failure is allowed if not admin
        if not ok then print("  [INFO] SeDebugPrivilege check: " .. tostring(p_err)) end
    end
end

-- 9. 静态等待函数测试
function TestProcess:test_Static_Wait_Helpers()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    local found_pid = win.process.wait(p.pid, 1000)
    lu.assertEquals(found_pid, p.pid)
    
    p:kill()
    
    local closed = win.process.wait_close(p.pid, 2000)
    lu.assertTrue(closed, "wait_close should return true")
    
    p:close()
end

function TestProcess:test_Exec_Table_Options()
    local p, err = win.process.exec({
        file = "cmd.exe",
        args = { "/c", "exit", "0" },
        env = { WIN_UTILS_EXEC_TABLE_TEST = "1" },
        show = 0,
        timeout = 2000,
    })
    lu.assertNotNil(p, "exec table options failed: " .. tostring(err))
    lu.assertEquals(win.process.exists(p.pid), 0, "short process should have exited")
    p:close()

    local p2, status = win.process.exec({
        file = "cmd.exe",
        args = { "/c", "ping", "-n", "30", "127.0.0.1", ">", "NUL" },
        show = 0,
        timeout = 100,
        kill_tree_on_timeout = true,
    })
    lu.assertNotNil(p2)
    lu.assertEquals(status, "timeout")
    ffi.C.Sleep(200)
    lu.assertEquals(win.process.exists(p2.pid), 0, "timed out process should be killed")
    p2:close()
end

function TestProcess:test_Popen_Timeout()
    lu.assertIsTable(win.process.popen)
    local out, code, status = win.process.popen.run("cmd.exe /c ping -n 30 127.0.0.1 > NUL", {
        timeout = 100,
        kill_on_timeout = true,
    })
    lu.assertIsString(out)
    lu.assertIsNumber(code)
    lu.assertEquals(status, "timeout")
end

function TestProcess:test_Exec_Capture()
    local res, err = win.process.exec({
        file = "cmd.exe",
        args = { "/c", "echo stdout-line" },
        show = 0,
        capture_stdout = true,
        timeout = 2000,
    })
    lu.assertNotNil(res, tostring(err))
    lu.assertEquals(res.exit_code, 0)
    lu.assertEquals(res.status, "exit")
    lu.assertStrContains(res.stdout, "stdout-line")

    local res2, err2 = win.process.exec({
        cmd = "cmd.exe /c echo stderr-line 1>&2",
        show = 0,
        capture_stdout = true,
        capture_stderr = true,
        timeout = 2000,
    })
    lu.assertNotNil(res2, tostring(err2))
    lu.assertEquals(res2.exit_code, 0)
    lu.assertStrContains(res2.stderr, "stderr-line")
end

function TestProcess:test_Exec_Capture_Timeout()
    local res, err = win.process.exec({
        cmd = "cmd.exe /c ping -n 30 127.0.0.1 > NUL",
        show = 0,
        capture_stdout = true,
        timeout = 100,
        kill_on_timeout = true,
    })
    lu.assertNotNil(res, tostring(err))
    lu.assertTrue(res.timed_out)
    lu.assertEquals(res.status, "timeout")
end

-- 10. 内存区域 (Memory Regions)
function TestProcess:test_Memory_Regions()
    local p = win.process.current()
    lu.assertNotNil(p)
    
    local regions, err = win.process.memory.list_regions(p.pid)
    lu.assertNotNil(regions, "list_regions failed: " .. tostring(err))
    lu.assertIsTable(regions)
    lu.assertTrue(#regions > 0)
    
    local found_any_file = false
    
    for _, r in ipairs(regions) do
        lu.assertIsNumber(r.addr)
        lu.assertIsNumber(r.size)
        if r.filename then
            found_any_file = true
            if r.protect_str then lu.assertIsString(r.protect_str) end
        end
    end
    
    lu.assertTrue(found_any_file, "No mapped filenames resolved")
    p:close()
end

-- 11. 独立的模块列表测试 (Modules)
function TestProcess:test_Modules()
    local pid = ffi.load("kernel32").GetCurrentProcessId()
    
    if win.process.module and win.process.module.list then
        local mods, err = win.process.module.list(pid)
        lu.assertNotNil(mods, "module.list failed: " .. tostring(err))
        lu.assertIsTable(mods)
        lu.assertTrue(#mods > 0)
        
        local found_ntdll = false
        for _, m in ipairs(mods) do
            lu.assertIsString(m)
            if m:lower():find("ntdll.dll") then
                found_ntdll = true
                break
            end
        end
        lu.assertTrue(found_ntdll, "ntdll.dll should be loaded in current process")
    else
        print("  [WARN] win.process.module API not found")
    end
end

-- 12. 句柄列表 (Handles)
function TestProcess:test_Handles()
    local pid = ffi.load("kernel32").GetCurrentProcessId()
    local list, err = win.process.handles.list(pid)
    lu.assertNotNil(list, "Handles list failed: " .. tostring(err))
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    if win.process.token.is_elevated() then
        local sys_handles, sys_err = win.process.handles.list_system()
        lu.assertNotNil(sys_handles, "System handles list failed: " .. tostring(sys_err))
        lu.assertIsTable(sys_handles)
        lu.assertTrue(#sys_handles > 100)
        
        if #sys_handles > 0 then
            local h = sys_handles[1]
            lu.assertIsNumber(h.pid)
            lu.assertIsNumber(h.val)
            -- [Check] Should be number now
            lu.assertIsNumber(h.obj, "Handle Object Pointer must be a number")
        end
    end
end
