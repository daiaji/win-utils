local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestDisk = {}

function TestDisk:setUp()
    self.is_admin = win.process.token.is_elevated()
    self.temp_vhd = os.getenv("TEMP") .. "\\test_disk_" .. os.time() .. ".vhdx"
end

function TestDisk:tearDown()
    if self.vhd_handle then
        -- 尝试分离
        win.disk.vhd.detach(self.vhd_handle)
        self.vhd_handle:close()
        self.vhd_handle = nil
    end
    
    -- 给系统一点时间释放文件锁
    ffi.C.Sleep(500)
    
    if win.fs.exists(self.temp_vhd) then
        os.remove(self.temp_vhd)
    end
end

function TestDisk:test_Physical_List()
    local drives = win.disk.physical.list()
    lu.assertIsTable(drives)
    for _, d in ipairs(drives) do
        lu.assertIsNumber(d.index)
        lu.assertIsNumber(d.size)
        lu.assertIsNumber(d.sector_size)
        print(string.format("  [INFO] Disk %d: %s (Bus: %s)", d.index, d.model, tostring(d.bus)))
    end
end

function TestDisk:test_Layout_IOCTL()
    if not self.is_admin then return end
    
    local pd, err = win.disk.physical.open(0, "r")
    if not pd then return end
    
    if win.disk.layout and win.disk.layout.get then
        local layout, l_err = win.disk.layout.get(pd)
        if layout then
            lu.assertIsTable(layout)
            lu.assertTrue(layout.style == "MBR" or layout.style == "GPT", "Unknown Disk Style")
            lu.assertIsTable(layout.parts)
        else
            print("  [WARN] GetLayout failed: " .. tostring(l_err))
        end
    end
    pd:close()
end

-- 全链路 VHD 测试：创建 -> 分区 -> 格式化 -> 读写 -> 扫描 -> 清理
function TestDisk:test_Full_VHD_Lifecycle()
    if not self.is_admin then 
        print("  [SKIP] Admin required for VHD Lifecycle Test")
        return 
    end

    print("  [STEP] 1. Create VHDX (512 MB)")
    local h, err = win.disk.vhd.create(self.temp_vhd, 512 * 1024 * 1024)
    lu.assertNotNil(h, "VHD Create failed: " .. tostring(err))
    self.vhd_handle = h
    
    print("  [STEP] 2. Attach VHD")
    local ok_att, att_err = win.disk.vhd.attach(h)
    lu.assertTrue(ok_att, "Attach failed: " .. tostring(att_err))
    
    print("  [STEP] 3. Wait for Physical Drive")
    local phys_path = win.disk.vhd.wait_for_physical_path(h, 5000)
    lu.assertNotNil(phys_path, "Physical path timeout")
    
    local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    lu.assertNotNil(idx, "Could not parse drive index from " .. phys_path)
    print("         -> Disk Index: " .. idx)
    
    print("  [STEP] 4. Wipe & Initialize Layout (GPT)")
    local drive, open_err = win.disk.physical.open(idx, "rw", true)
    lu.assertNotNil(drive, "Open physical drive failed: " .. tostring(open_err))
    
    -- 擦除原有数据
    drive:wipe_layout()
    -- 通知 VDS 刷新
    win.disk.vds.clean(idx)
    
    -- 定义分区表: 1个数据分区，剩余空间
    local parts = {
        {
            type = win.disk.types.GPT.DATA,
            offset = 1024 * 1024, -- 1MB 对齐
            size = drive.size - (2 * 1024 * 1024), -- 留一点尾部
            name = "LuaWinUtils Test Partition",
            attr = 0
        }
    }
    
    local ok_layout, err_layout = win.disk.layout.apply(drive, "GPT", parts)
    lu.assertTrue(ok_layout, "Apply Layout failed: " .. tostring(err_layout))
    
    drive:close() -- 关闭句柄以便后续格式化独占
    
    -- 等待系统识别新分区
    ffi.C.Sleep(2000)
    
    print("  [STEP] 5. Format Partition (NTFS)")
    -- format(idx, offset, fs, label, opts)
    local ok_fmt, err_fmt = win.disk.format.format(idx, parts[1].offset, "NTFS", "LUA_TEST", { compress = true })
    lu.assertTrue(ok_fmt, "Format failed: " .. tostring(err_fmt))
    
    print("  [STEP] 6. Assign Drive Letter")
    local ok_assign, mount_point = win.disk.volume.assign(idx, parts[1].offset)
    lu.assertTrue(ok_assign, "Assign failed: " .. tostring(mount_point))
    print("         -> Mounted at: " .. mount_point)
    
    print("  [STEP] 7. File System Verification")
    local test_file = mount_point .. "verification.txt"
    local f = io.open(test_file, "w")
    lu.assertNotNil(f, "Failed to create file on new drive")
    f:write("Lua Win Utils VHD Test")
    f:close()
    
    lu.assertTrue(win.fs.exists(test_file), "File created but not found?")
    local content = io.lines(test_file)()
    lu.assertEquals(content, "Lua Win Utils VHD Test")
    
    print("  [STEP] 8. Surface Scan (Read Test)")
    -- 重新打开进行读取扫描
    local drive_chk = win.disk.physical.open(idx, "r", true)
    local ok_scan, msg_scan = win.disk.surface.scan(drive_chk, nil, "read")
    lu.assertTrue(ok_scan, "Surface scan failed: " .. tostring(msg_scan))
    drive_chk:close()
    
    print("  [STEP] 9. Cleanup")
    -- 卸载盘符
    win.disk.mount.unmount(mount_point:sub(1, 2))
    
    -- Detach 在 tearDown 中也会尝试，但这里显式调用以验证流程
    local ok_det, err_det = win.disk.vhd.detach(h)
    lu.assertTrue(ok_det, "Detach failed: " .. tostring(err_det))
    
    print("  [PASS] Full VHD Lifecycle Test Completed")
end

function TestDisk:test_Image_Ops()
    if not self.is_admin then return end
    
    local h = win.disk.vhd.create(self.temp_vhd, 4 * 1024 * 1024)
    win.disk.vhd.attach(h)
    self.vhd_handle = h
    
    local phys_path = win.disk.vhd.wait_for_physical_path(h)
    local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    local drive = win.disk.physical.open(idx, "rw", true)
    
    local img_path = os.getenv("TEMP") .. "\\test_src_" .. os.time() .. ".img"
    local f = io.open(img_path, "wb")
    local pattern = "LUA_WIN_UTILS_TEST"
    for i=1, 1024 do f:write(string.rep(pattern, 64)) end 
    f:close()
    
    local w_ok, w_err = win.disk.image.write(img_path, drive)
    lu.assertTrue(w_ok, "Image write failed: " .. tostring(w_err))
    
    local dump_path = os.getenv("TEMP") .. "\\test_dump_" .. os.time() .. ".img"
    local r_ok, r_err = win.disk.image.read(drive, dump_path)
    lu.assertTrue(r_ok, "Image read failed: " .. tostring(r_err))
    
    drive:close()
    
    local f1 = io.open(img_path, "rb")
    local f2 = io.open(dump_path, "rb")
    local s1 = f1:read(1024)
    local s2 = f2:read(1024)
    f1:close(); f2:close()
    
    lu.assertEquals(s1, s2)
    os.remove(img_path)
    os.remove(dump_path)
end

function TestDisk:test_BitLocker()
    if not self.is_admin then return end
    local status, err = win.disk.bitlocker.get_status("C:")
    if status then
        lu.assertTrue(status == "Locked" or status == "None" or status == "Off")
    else
        print("  [WARN] BitLocker check failed: " .. tostring(err))
    end
end

function TestDisk:test_Volume_List()
    local vols, err = win.disk.volume.list()
    lu.assertNotNil(vols, "Vol list failed: " .. tostring(err))
    lu.assertTrue(#vols > 0)
    local found_c = false
    for _, v in ipairs(vols) do
        lu.assertIsString(v.guid_path)
        for _, mp in ipairs(v.mount_points) do
            if mp:match("^[Cc]:") then found_c = true end
        end
    end
    lu.assertTrue(found_c, "C: drive volume should be listed")
end