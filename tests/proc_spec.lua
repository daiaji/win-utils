-- tests/proc_utils_spec.lua
-- Unit tests for proc_utils_ffi.lua using luaunit.
-- [REFACTOR] Tests updated for the pure OOP API with full feature coverage.

-- 1. Configure path to find 'proc_utils_ffi.lua' and 'luaunit.lua'
package.path = package.path .. ';./?.lua;./vendor/luaunit/?.lua;../?.lua;../vendor/luaunit/?.lua'

local status, lu = pcall(require, 'luaunit')
if not status then
    print("[ERROR] Could not find 'luaunit'.")
    print("  Current package.path: " .. package.path)
    print("  Ensure you have run: git submodule update --init --recursive")
    os.exit(1)
end

local ffi = require("ffi")

-- 2. Load the library under test
local proc_status, proc = pcall(require, 'win-utils.proc')
if not proc_status then
    print("[ERROR] Could not find 'win-utils.proc'.")
    print("  Error: " .. tostring(proc))
    os.exit(1)
end

if not proc._OS_SUPPORT then
    print("Skipping tests: proc_utils-ffi only supports Windows.")
    os.exit(0)
end

-- 3. Local Helpers
local function table_isempty(t)
    return next(t) == nil
end

-- 4. Test Suite Definition
TestProcUtils = {}

-- [MODIFIED] Use cmd.exe to wrap ping and redirect stdout to NUL to suppress CI logs
local TEST_PROC_NAME = "cmd.exe"
local TEST_COMMAND = 'cmd.exe /c "ping -n 30 127.0.0.1 > NUL"'
local TEST_COMMAND_WITH_ARGS = 'cmd.exe /c "ping -n 4 127.0.0.1 > NUL"'
-- CMD_PING_COMMAND already redirects to NUL, so it's fine
local CMD_PING_COMMAND = 'cmd.exe /c "ping -n 10 127.0.0.1 > NUL"'
local UNICODE_FILENAME = "测试文件.txt"

function TestProcUtils:setUp()
    print("\n[SETUP] Cleaning up environment before test...")
    self:tearDown()
    print("[SETUP] Cleanup complete.")
end

function TestProcUtils:tearDown()
    local function kill_all_by_name(name)
        local pids = proc.find_all(name)
        if pids and not table_isempty(pids) then
            print("  [TEARDOWN] Cleaning up lingering '" .. name .. "': " .. table.concat(pids, ", "))
            for _, pid in ipairs(pids) do
                proc.terminate_by_pid(pid, 0)
            end
        end
    end

    -- [MODIFIED] Cleanup matching the new TEST_PROC_NAME
    kill_all_by_name(TEST_PROC_NAME)
    kill_all_by_name("ping.exe")
    kill_all_by_name("whoami.exe")

    os.remove(UNICODE_FILENAME)
    ffi.C.Sleep(100)
end

-------------------------------------------------------------------------------
-- 1. OOP Wrapper & Static Function Tests
-------------------------------------------------------------------------------

function TestProcUtils:test_exec_and_exists()
    print("[RUNNING] test_exec_and_exists")
    local p = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p, "proc.exec should return a process object")
    lu.assertTrue(p.pid > 0, "Process object should have a valid PID")
    print("  [DEBUG] Launched: " .. p.pid)
    ffi.C.Sleep(500)

    local exists_name = proc.exists(TEST_PROC_NAME)
    lu.assertTrue(exists_name > 0, "proc.exists(name) failed")

    local exists_pid = proc.exists(p.pid)
    lu.assertEquals(exists_pid, p.pid, "proc.exists(pid) mismatch")

    local exists_fake = proc.exists("non_existent_123.exe")
    lu.assertEquals(exists_fake, 0, "proc.exists(fake) should be 0")

    p:terminate()
    print("[SUCCESS] test_exec_and_exists")
end

function TestProcUtils:test_open_and_wait()
    print("[RUNNING] test_open_and_wait")
    local p_created = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p_created, "CreateProcess failed")

    local p_opened = proc.open_by_pid(p_created.pid)
    lu.assertNotIsNil(p_opened, "OpenByPid failed")

    -- WaitForProcessExit (Timeout expected)
    local exited = p_opened:wait_for_exit(200)
    lu.assertFalse(exited, "wait_for_exit should timeout (return false)")

    -- Terminate
    local ok = p_opened:terminate()
    lu.assertTrue(ok, "terminate failed")

    -- WaitForProcessExit (Success expected)
    local exited_after = p_opened:wait_for_exit(1000)
    lu.assertTrue(exited_after, "wait_for_exit should succeed (return true)")

    print("[SUCCESS] test_open_and_wait")
end

function TestProcUtils:test_terminate_and_wait_close()
    print("[RUNNING] test_terminate_and_wait_close")
    local p = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(500)

    local ok = proc.terminate_by_pid(p.pid, 0)
    lu.assertTrue(ok, "terminate_by_pid failed")

    local closed = proc.wait_close(p.pid, 3000)
    lu.assertTrue(closed, "wait_close failed (expected true)")
    print("[SUCCESS] test_terminate_and_wait_close")
end

function TestProcUtils:test_wait_for_process_timeout_and_success()
    print("[RUNNING] test_wait_for_process_timeout_and_success")
    -- 1. Test Timeout
    local start = ffi.C.GetTickCount64()
    local pid, err_code = proc.wait("fake_proc_123.exe", 500)
    local duration = tonumber(ffi.C.GetTickCount64() - start)
    lu.assertIsNil(pid, "wait should return nil on timeout")
    lu.assertNotIsNil(err_code, "wait should return an error code on timeout")
    lu.assertTrue(duration >= 400, "Wait duration too short")

    -- 2. Test Success
    local p_launched = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p_launched)

    local found_pid = proc.wait(TEST_PROC_NAME, 2000)
    lu.assertEquals(found_pid, p_launched.pid, "wait did not find the correct PID")

    p_launched:terminate()
    print("[SUCCESS] test_wait_for_process_timeout_and_success")
end

function TestProcUtils:test_get_path_and_command_line()
    print("[RUNNING] test_get_path_and_command_line")
    local p = proc.exec(TEST_COMMAND_WITH_ARGS, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(500)

    -- GetPath
    local path = p:get_path()
    lu.assertNotIsNil(path, "get_path failed")
    lu.assertStrContains(path:lower(), TEST_PROC_NAME, "Path mismatch")

    -- GetCommandLine
    local cmdline = p:get_command_line()
    lu.assertNotIsNil(cmdline)
    lu.assertStrContains(cmdline, "-n 4", "Command line mismatch")

    p:terminate(0)
    print("[SUCCESS] test_get_path_and_command_line")
end

function TestProcUtils:test_set_priority()
    print("[RUNNING] test_set_priority")
    local p = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(500)

    -- Set valid priority
    local ok, err_code, err_msg = p:set_priority("L")
    lu.assertTrue(ok, "set_priority('L') failed: " .. tostring(err_msg))

    -- Set invalid priority
    local ok_fail, err_fail = p:set_priority("X")
    lu.assertIsNil(ok_fail, "set_priority('X') should have failed")
    lu.assertNotIsNil(err_fail, "set_priority with invalid arg should return an error code")

    p:terminate(0)
    print("[SUCCESS] test_set_priority")
end

function TestProcUtils:test_get_parent_and_terminate_tree()
    print("[RUNNING] test_get_parent_and_terminate_tree")
    local parent_p = proc.exec(CMD_PING_COMMAND, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(parent_p, "Parent process launch failed")

    ffi.C.Sleep(1000) -- Give time for child to spawn

    -- [NOTE] Even though parent is cmd.exe, it spawns ping.exe.
    -- We want to verify we can find the child.
    local child_p = proc.open_by_name("ping.exe")
    lu.assertNotIsNil(child_p, "Child process not found")

    local child_info = child_p:get_info()
    lu.assertNotIsNil(child_info)
    lu.assertEquals(child_info.parent_pid, parent_p.pid, "Parent PID mismatch")

    local ok = parent_p:terminate_tree()
    lu.assertTrue(ok, "terminate_tree failed")

    ffi.C.Sleep(500)
    lu.assertEquals(proc.exists(parent_p.pid), 0, "Parent remains")
    lu.assertEquals(proc.exists(child_p.pid), 0, "Child remains")
    print("[SUCCESS] test_get_parent_and_terminate_tree")
end

function TestProcUtils:test_find_all_processes()
    print("[RUNNING] test_find_all_processes")
    local p1 = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    local p2 = proc.exec(TEST_COMMAND, nil, proc.constants.SW_HIDE)
    ffi.C.Sleep(1000)

    local pids = proc.find_all(TEST_PROC_NAME)
    lu.assertTrue(#pids >= 2, "Count < 2")

    local found = false
    for _, pid in ipairs(pids) do
        if pid == p1.pid then
            found = true
            break
        end
    end
    lu.assertTrue(found, "P1 not found in list")

    p1:terminate()
    p2:terminate()
    print("[SUCCESS] test_find_all_processes")
end

function TestProcUtils:test_get_full_process_info()
    print("[RUNNING] test_get_full_process_info")
    local p = proc.exec(TEST_COMMAND_WITH_ARGS, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(500)

    local info = p:get_info()
    lu.assertNotIsNil(info, "get_info failed")

    lu.assertEquals(info.pid, p.pid)
    lu.assertStrContains(info.exe_path:lower(), TEST_PROC_NAME)
    lu.assertStrContains(info.command_line, "-n 4")
    lu.assertTrue(info.session_id >= 0)

    -- Test invalid pid
    local bad_p = proc.open_by_pid(999999)
    lu.assertIsNil(bad_p)

    p:terminate(0)
    print("[SUCCESS] test_get_full_process_info")
end

function TestProcUtils:test_create_as_system()
    print("[RUNNING] test_create_as_system")
    local p, err_code, err_msg = proc.exec_as_system("whoami.exe", nil, proc.constants.SW_HIDE)

    if p then
        print("  [DEBUG] Admin Success. PID: " .. p.pid)
        ffi.C.Sleep(500)
        lu.assertEquals(proc.exists(p.pid), 0, "Process should have exited quickly")
    else
        print("  [DEBUG] Expected CI/User Fail. Error: " .. err_code .. " (" .. err_msg .. ")")
        -- Known error codes for non-admin/no-session environments
        local allowed = { [5] = true, [6] = true, [1314] = true, [1008] = true, [1157] = true }
        if not allowed[err_code] then
            lu.fail("Unexpected error code from exec_as_system: " .. err_code)
        end
    end
    print("[SUCCESS] test_create_as_system")
end

function TestProcUtils:test_oop_unicode_support()
    print("[RUNNING] test_oop_unicode_support")
    local unicode_arg = "arg_" .. UNICODE_FILENAME
    -- This command already redirects to NUL
    local cmd = string.format('cmd.exe /c "ping -n 2 127.0.0.1 > NUL & rem %s"', unicode_arg)
    local p = proc.exec(cmd, nil, proc.constants.SW_HIDE)
    lu.assertNotIsNil(p)
    ffi.C.Sleep(500)
    local cl = p:get_command_line()
    if cl then
        lu.assertStrContains(cl, unicode_arg)
    end
    p:terminate_tree()
    print("[SUCCESS] test_oop_unicode_support")
end
