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
    local p = win.process.exec(TEST_CMD_LONG, nil, 0) -- SW_HIDE
    lu.assertNotNil(p, "Exec failed")
    lu.assertTrue(p.pid > 0)
    
    -- 验证 exists (PID)
    lu.assertEquals(win.process.exists(p.pid), p.pid)
    
    -- 验证 exists (Name) - 来自旧版测试的逻辑
    local found_pid = win.process.exists("cmd.exe")
    lu.assertTrue(found_pid > 0)
    
    -- 终止 (使用新 API p:kill)
    lu.assertTrue(p:kill())
    
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
    
    lu.assertFalse(res, "Wait should timeout")
    
    p:kill()
    
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
    
    -- 使用 Lua-Ext 的 findiIf 验证
    local _, found1 = list:findiIf(function(x) return x.pid == p1.pid end)
    local _, found2 = list:findiIf(function(x) return x.pid == p2.pid end)
    
    lu.assertNotNil(found1)
    lu.assertNotNil(found2)
    
    -- 验证父进程ID (PPID)
    lu.assertIsNumber(found1.parent_pid)
    lu.assertIsString(found1.name)
    
    p1:kill(); p1:close()
    p2:kill(); p2:close()
end

-- 5. 挂起与恢复 (Suspend/Resume)
function TestProcess:test_Suspend_Resume()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    
    -- 挂起
    lu.assertTrue(p:suspend())
    
    -- 恢复
    lu.assertTrue(p:resume())
    
    p:kill()
    p:close()
end

-- 6. 进程树终止 (Kill Tree) - 恢复旧版详细逻辑
function TestProcess:test_Tree_Kill()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    -- 等待子进程生成 (cmd -> ping)
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
        
        -- 使用 Tree 模式查杀
        -- 新版 API 使用 kill("tree")
        p:kill("tree")
        ffi.C.Sleep(200)
        
        -- 验证父子全挂
        lu.assertEquals(win.process.exists(p.pid), 0, "Parent should be dead")
        lu.assertEquals(win.process.exists(child_pid), 0, "Child should be dead")
    else
        print("  [WARN] Could not spawn child process for tree test (CI env?)")
        p:kill()
    end
    p:close()
end

-- 7. 令牌信息 (Token Info)
function TestProcess:test_Token_Info()
    local t = win.process.token.open_current(8) -- QUERY
    lu.assertNotNil(t)
    
    local user = win.process.token.get_user(t)
    lu.assertIsString(user)
    print("  [INFO] Current User: " .. user)
    
    local integrity = win.process.token.get_integrity_level(t)
    if integrity then
        print("  [INFO] Integrity: " .. integrity)
    end
    t:close()
    
    -- 静态辅助函数
    lu.assertTrue(type(win.process.token.is_elevated()) == "boolean")
    
    -- [Restored] 恢复旧版特权检查测试
    if win.process.token.enable_privilege then
        -- SeDebugPrivilege 通常需要管理员，如果不是管理员会返回 false 但不报错
        local ok = win.process.token.enable_privilege("SeDebugPrivilege")
        lu.assertIsBoolean(ok)
    end
end

-- 8. 静态等待函数测试
function TestProcess:test_Static_Wait_Helpers()
    local p = win.process.exec(TEST_CMD_LONG, nil, 0)
    lu.assertNotNil(p)
    
    -- 测试 wait (等待进程出现)
    local found_pid = win.process.wait(p.pid, 1000)
    lu.assertEquals(found_pid, p.pid)
    
    -- 测试 wait_close (等待进程结束)
    p:kill()
    
    local closed = win.process.wait_close(p.pid, 2000)
    lu.assertTrue(closed, "wait_close should return true")
    
    p:close()
end

-- 9. 内存区域 (Memory Regions)
function TestProcess:test_Memory_Regions()
    local p = win.process.current()
    lu.assertNotNil(p)
    
    local regions = win.process.memory.list_regions(p.pid)
    lu.assertIsTable(regions)
    lu.assertTrue(#regions > 0)
    
    local found_any_file = false
    
    for _, r in ipairs(regions) do
        -- 验证结构体字段
        lu.assertIsNumber(r.addr)
        lu.assertIsNumber(r.size)
        if r.filename then
            found_any_file = true
            -- 验证保护属性字符串是否生成 (新版特性)
            if r.protect_str then
                lu.assertIsString(r.protect_str)
            end
        end
    end
    
    lu.assertTrue(found_any_file, "No mapped filenames resolved")
    p:close()
end

-- 10. [Restored] 独立的模块列表测试 (Modules)
-- 之前为了精简代码将其与 Memory 合并，现在独立出来以保证完整覆盖率
function TestProcess:test_Modules()
    local pid = ffi.load("kernel32").GetCurrentProcessId()
    
    -- 检查 API 是否存在 (win.process.module)
    if win.process.module and win.process.module.list then
        local mods = win.process.module.list(pid)
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

-- 11. 句柄列表 (Handles)
function TestProcess:test_Handles()
    local pid = ffi.load("kernel32").GetCurrentProcessId()
    local list = win.process.handles.list(pid)
    lu.assertIsTable(list)
    lu.assertTrue(#list > 0)
    
    -- 系统级句柄列表 (需要提升权限或运气)
    if win.process.token.is_elevated() then
        local sys_handles = win.process.handles.list_system()
        lu.assertIsTable(sys_handles)
        -- 整个系统的句柄数通常成千上万
        lu.assertTrue(#sys_handles > 100)
        
        -- 检查结构
        local h = sys_handles[1]
        lu.assertIsNumber(h.pid)
        lu.assertIsNumber(h.handle)
        lu.assertIsNumber(h.object_addr)
    end
end