local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local kernel32 = require('ffi.req') 'Windows.sdk.kernel32'

TestVhdStress = {}

function TestVhdStress:setUp()
    if not win.process.token.is_elevated() then 
        print("SKIP: Admin required") 
        return 
    end
    self.files_to_clean = {}
end

function TestVhdStress:tearDown()
    for _, f in ipairs(self.files_to_clean) do
        -- 尝试清理残留的 VHD
        local h = win.disk.vhd.open(f)
        if h then
            win.disk.vhd.detach(h)
            h:close()
        end
        os.remove(f)
    end
end

-- 模拟 Rufus 流程：创建 -> 挂载 -> 准备磁盘(Pre-Wipe/Layout) -> 格式化
function TestVhdStress:test_Rapid_Lifecycle()
    local iterations = 5
    print("\n=== Starting VHD Stress Test ("..iterations.." cycles) ===")
    
    for i = 1, iterations do
        local vhd_path = os.getenv("TEMP") .. "\\rufus_clone_test_" .. os.time() .. "_" .. i .. ".vhdx"
        table.insert(self.files_to_clean, vhd_path)
        
        io.write(string.format("  [%d/%d] Creating VHDX... ", i, iterations))
        
        -- 1. 创建 (使用 Full Physical Allocation)
        local hVhd, err = win.disk.vhd.create(vhd_path, 64 * 1024 * 1024, { dynamic = false })
        lu.assertNotNil(hVhd, "Create failed: " .. tostring(err))
        
        -- 2. 挂载
        local ok_att = win.disk.vhd.attach(hVhd)
        lu.assertTrue(ok_att, "Attach failed")
        
        local phys_path = win.disk.vhd.wait_for_physical_path(hVhd)
        local drive_idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
        lu.assertNotNil(drive_idx)
        
        -- 3. 准备磁盘 (核心测试点：Pre-Wipe, Lock, VDS Refresh)
        -- 这步如果失败，通常是因为“设备被占用”或“卷未刷新”
        local prep_ok, plan = win.disk.prepare_drive(drive_idx, "GPT", {
            create_esp = true, -- 强制创建 ESP，增加复杂性
            label = "STRESS_"..i
        })
        lu.assertTrue(prep_ok, "Prepare failed: " .. tostring(plan)) -- plan 在失败时包含错误信息
        
        -- 4. 格式化 (测试逻辑卷轮询是否生效)
        -- prepare_drive 结束后，逻辑卷应该已经就绪
        -- 我们尝试格式化数据分区 (通常是最后一个分区)
        local data_part = plan[#plan]
        local fmt_ok, fmt_msg = win.disk.format.format(drive_idx, data_part.offset, "NTFS", "DATA_"..i)
        
        if not fmt_ok then
            print("\n    [FAIL] Format failed: " .. tostring(fmt_msg))
            -- 尝试诊断：列出当前卷
            local vols = win.disk.volume.list()
            print("    [DEBUG] Visible Volumes:")
            for _, v in ipairs(vols) do print("      "..v.guid_path) end
        end
        lu.assertTrue(fmt_ok, "Format failed: " .. tostring(fmt_msg))
        
        -- 5. 写入测试 (测试有状态写入重试)
        local drive = win.disk.physical.open(drive_idx, "rw", true)
        lu.assertNotNil(drive)
        -- 故意写入非对齐长度，测试内部对齐逻辑
        local raw_data = string.rep("A", 513) 
        local w_ok, w_err = drive:write(data_part.offset + 4096, raw_data)
        lu.assertTrue(w_ok, "Write failed: " .. tostring(w_err))
        drive:close()
        
        -- 6. 清理
        win.disk.mount.unmount_all_on_disk(drive_idx)
        win.disk.vhd.detach(hVhd)
        hVhd:close()
        
        io.write("OK\n")
        kernel32.Sleep(500) -- 稍微喘口气，让 Windows 释放文件锁
    end
end