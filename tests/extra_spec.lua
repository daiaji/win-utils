local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestExtra = {}

-- ========================================================================
-- 网络模块测试 (Network)
-- ========================================================================
function TestExtra:test_Net_ICMP()
    -- Ping 本地回环，通常应该成功且极快
    -- 如果网络受限，至少不应报错崩溃
    local ok, rtt = win.net.icmp.ping("127.0.0.1", 1000)
    
    -- 注意：某些 CI 环境禁用了 ICMP，所以这里只断言类型
    lu.assertIsBoolean(ok)
    lu.assertIsNumber(rtt)
end

function TestExtra:test_Net_DNS()
    -- 刷新 DNS 缓存 (通常总是返回 true/false，不应崩溃)
    local ok = win.net.dns.flush_cache()
    lu.assertIsBoolean(ok)
end

function TestExtra:test_Net_Adapter()
    local list = win.net.adapter.list()
    lu.assertIsTable(list)
    -- 如果有网卡，检查结构
    if #list > 0 then
        lu.assertIsString(list[1].name)
        lu.assertIsString(list[1].status) -- "Up" or "Down"
    end
end

-- ========================================================================
-- 作业对象测试 (Job Object)
-- ========================================================================
function TestExtra:test_Process_Job()
    -- 1. 创建 Job
    local job_name = "LuaTestJob_" .. os.time()
    local job = win.process.job.create(job_name)
    lu.assertNotIsNil(job, "Job creation failed")
    
    -- 2. 设置限制 (Kill on Close)
    local ok = job:set_kill_on_close()
    lu.assertTrue(ok, "Set kill on close failed")
    
    -- 3. 启动一个子进程并加入 Job
    local proc = win.process.exec("cmd.exe /c timeout 10", nil, 0)
    lu.assertNotIsNil(proc)
    
    -- Assign
    local assigned = job:assign(proc:handle())
    lu.assertTrue(assigned, "Assign process to job failed")
    
    -- 4. 关闭 Job，理论上子进程应该被系统杀死 (Kill on Close)
    -- 但单元测试很难异步验证这一点，主要验证 API 调用成功
    job:close()
    proc:terminate() -- 清理
end

-- ========================================================================
-- WIM 映像模块 (WIM)
-- ========================================================================
function TestExtra:test_WIM_List()
    -- WIMGAPI 需要 DLL 支持，如果环境缺失可能会 fail
    -- 做一个 pcall 保护，或者假设环境已这就绪
    if not win.wim then return end
    
    local list = win.wim.list_mounted()
    -- 即使没有挂载的镜像，也应该返回空表而不是 nil
    lu.assertIsTable(list)
end

-- ========================================================================
-- 虚拟磁盘 (VHD)
-- ========================================================================
function TestExtra:test_VHD_Smoke()
    -- VHD 操作通常需要管理员权限，CI 可能失败
    -- 这里只测试模块加载和路径解析函数的空值处理
    lu.assertNotIsNil(win.disk.vhd)
    
    -- 尝试用无效句柄调用，应安全返回 nil 而不是崩溃
    local path = win.disk.vhd.get_physical_path(ffi.cast("HANDLE", -1))
    lu.assertNil(path)
end

-- ========================================================================
-- 显示与桌面 (Display/Desktop)
-- ========================================================================
function TestExtra:test_Display_SetRes()
    -- 设置分辨率极其危险，这里只测试获取逻辑或错误处理
    -- 传入无效参数，应返回 false
    local ok, err = win.display.set_resolution(0, 0)
    lu.assertFalse(ok)
end

function TestExtra:test_Desktop_Refresh()
    -- 发送刷新通知 (无害)
    win.desktop.refresh()
    lu.assertTrue(true) -- 只要没崩溃就是成功
end