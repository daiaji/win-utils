local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local kernel32 = require('ffi.req') 'Windows.sdk.kernel32'

TestDisk = {}

function TestDisk:setUp()
    self.is_admin = win.process.token.is_elevated()
    -- 使用 512MB 大小，足够创建多个分区进行测试
    self.temp_vhd = os.getenv("TEMP") .. "\\test_vhd_" .. os.time() .. ".vhdx"
    self.mount_points = {}
    self.vhd_handle = nil
    
    -- 临时文件用于镜像测试
    self.img_src = os.getenv("TEMP") .. "\\test_src_" .. os.time() .. ".img"
    self.img_dst = os.getenv("TEMP") .. "\\test_dst_" .. os.time() .. ".img"
end

function TestDisk:tearDown()
    -- 1. 卸载所有挂载点
    if self.mount_points then
        for _, letter in ipairs(self.mount_points) do
            win.disk.mount.unmount(letter)
        end
    end

    -- 2. 分离 VHD
    if self.vhd_handle then
        win.disk.vhd.detach(self.vhd_handle)
        self.vhd_handle:close()
        self.vhd_handle = nil
    end

    -- 3. 清理文件
    local files_to_clean = { self.temp_vhd, self.img_src, self.img_dst }
    for _, f in ipairs(files_to_clean) do
        for i=1, 5 do
            if not win.fs.exists(f) then break end
            local ok = os.remove(f)
            if ok then break end
            kernel32.Sleep(100)
        end
    end
end

-- 辅助：带重试的卷标验证
local function verify_volume_label(target_mount, expected_label, timeout_ms)
    local start = kernel32.GetTickCount()
    local limit = timeout_ms or 5000
    
    while true do
        local vols = win.disk.volume.list()
        if vols then
            for _, v in ipairs(vols) do
                for _, mp in ipairs(v.mount_points) do
                    -- 路径匹配 (注意 API 可能返回长路径格式)
                    if mp:lower():find(target_mount:lower(), 1, true) then
                        if v.label == expected_label then
                            return true, v.label -- Success
                        end
                        -- 如果找到了挂载点但 label 不匹配 (可能是 nil 或旧值)，继续等待
                        if (kernel32.GetTickCount() - start) > limit then
                            return false, v.label -- Timeout, return actual
                        end
                    end
                end
            end
        end
        
        if (kernel32.GetTickCount() - start) > limit then return false, "Mount point not found" end
        kernel32.Sleep(500)
    end
end

-- =============================================================================
-- [Integration Test] VHD 全生命周期与功能集成测试
-- =============================================================================

function TestDisk:test_VHD_Integrated_Lifecycle()
    if not self.is_admin then 
        print("\n  [SKIP] Administrator privileges required for Disk tests")
        return 
    end

    print("\n  === Starting Integrated VHD Lifecycle Test ===")

    -- [Phase 1] 虚拟磁盘创建与识别
    print("  [1/12] Creating & Attaching VHDX (512MB)...")
    local h, err = win.disk.vhd.create(self.temp_vhd, 512 * 1024 * 1024, { dynamic = false })
    lu.assertNotNil(h, "VHD Create failed: " .. tostring(err))
    self.vhd_handle = h

    local ok_att, err_att = win.disk.vhd.attach(h)
    lu.assertTrue(ok_att, "Attach failed: " .. tostring(err_att))

    local phys_path = win.disk.vhd.wait_for_physical_path(h, 5000)
    lu.assertNotNil(phys_path, "Timeout resolving physical path")
    local drive_index = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    lu.assertNotNil(drive_index, "Could not parse drive index")
    print(string.format("         Target: PhysicalDrive%d", drive_index))

    -- [Feature Test: Physical List] 验证新磁盘是否出现在列表中
    print("  [2/12] Verifying Physical Drive List...")
    local drives = win.disk.physical.list()
    local found_in_list = false
    for _, d in ipairs(drives) do
        if d.index == drive_index then
            found_in_list = true
            lu.assertTrue(d.size >= 510 * 1024 * 1024) 
        end
    end
    lu.assertTrue(found_in_list, "Created VHD not found in win.disk.physical.list()")

    -- [Phase 2] 裸机操作 (Raw I/O)
    local drive = win.disk.physical.open(drive_index, "rw", "exclusive")
    lu.assertNotNil(drive, "Open drive failed")
    
    local locked, lock_msg = drive:lock(true)
    lu.assertTrue(locked, "Lock failed: " .. tostring(lock_msg))

    -- [Feature Test: Image Ops] 镜像读写测试
    print("  [3/12] Testing Image Write/Read...")
    local f = io.open(self.img_src, "wb")
    local pattern = "WIN_UTILS_TEST_PATTERN"
    for i=1, 1024 do f:write(string.rep(pattern, 4)) end 
    f:close()
    
    local w_ok, w_err = win.disk.image.write(self.img_src, drive)
    lu.assertTrue(w_ok, "Image write failed: " .. tostring(w_err))
    
    local r_ok, r_err = win.disk.image.read(drive, self.img_dst)
    lu.assertTrue(r_ok, "Image read failed: " .. tostring(r_err))
    
    local f1 = io.open(self.img_src, "rb"); local s1 = f1:read(1024)
    local f2 = io.open(self.img_dst, "rb"); local s2 = f2:read(1024)
    f1:close(); f2:close()
    lu.assertEquals(s1, s2, "Image verify failed")

    -- [Feature Test: Surface Scan] 表面扫描测试
    print("  [4/12] Running Surface Scan (Write Mode)...")
    local scan_ok, scan_msg = win.disk.surface.scan(drive, function(p) return true end, "write", { 0x55, 0xAA })
    lu.assertTrue(scan_ok, "Surface scan failed: " .. tostring(scan_msg))

    -- [Phase 3] 分区管理
    print("  [5/12] Applying GPT Partition Layout...")
    drive:wipe_layout() 
    
    local ONE_MB = 1024 * 1024
    local parts = {
        { name = "EFI System", gpt_type = win.disk.types.GPT.ESP, offset = 1 * ONE_MB, size = 100 * ONE_MB, attr = win.disk.types.GPT.FLAGS.NO_DRIVE_LETTER },
        { name = "Data NTFS", gpt_type = win.disk.types.GPT.DATA, offset = 101 * ONE_MB, size = 200 * ONE_MB },
        { name = "Data FAT32", gpt_type = win.disk.types.GPT.DATA, offset = 302 * ONE_MB, size = 100 * ONE_MB }
    }
    
    local layout_ok, layout_err = win.disk.layout.apply(drive, "GPT", parts)
    lu.assertTrue(layout_ok, "Layout apply failed: " .. tostring(layout_err))

    -- [Feature Test: Layout IOCTL] 验证写入的分区表
    print("  [6/12] Verifying Partition Layout...")
    local layout = win.disk.layout.get(drive)
    lu.assertNotNil(layout, "Layout get failed")
    lu.assertEquals(layout.style, "GPT")
    lu.assertEquals(#layout.parts, 3)
    lu.assertEquals(layout.parts[2].off, 101 * ONE_MB)
    lu.assertEquals(layout.parts[3].len, 100 * ONE_MB)

    drive:close() 
    win.disk.vds.refresh_layout()
    kernel32.Sleep(1000)

    -- [Phase 4] 卷管理与格式化
    print("  [7/12] Formatting Partitions (NTFS & FAT32)...")
    
    local ok_fmt1, err_fmt1 = win.disk.format.format(drive_index, 101 * ONE_MB, "NTFS", "TEST_NTFS")
    lu.assertTrue(ok_fmt1, "Format NTFS failed: " .. tostring(err_fmt1))
    
    local ok_fmt2, err_fmt2 = win.disk.format.format(drive_index, 302 * ONE_MB, "FAT32", "TEST_FAT")
    lu.assertTrue(ok_fmt2, "Format FAT32 failed: " .. tostring(err_fmt2))

    print("  [8/12] Mounting Volumes...")
    local ok_mnt1, l1 = win.disk.volume.assign(drive_index, 101 * ONE_MB)
    lu.assertTrue(ok_mnt1, "Mount NTFS failed: " .. tostring(l1))
    table.insert(self.mount_points, l1)
    
    local ok_mnt2, l2 = win.disk.volume.assign(drive_index, 302 * ONE_MB)
    lu.assertTrue(ok_mnt2, "Mount FAT32 failed: " .. tostring(l2))
    table.insert(self.mount_points, l2)
    
    print(string.format("         Mounted at %s and %s", l1, l2))

    -- [Feature Test: Volume List] 验证卷列表
    print("  [9/12] Verifying Volume List...")
    
    local found_ntfs, label_ntfs = verify_volume_label(l1, "TEST_NTFS")
    lu.assertTrue(found_ntfs, "NTFS Volume verify failed. Got label: " .. tostring(label_ntfs))
    
    local found_fat, label_fat = verify_volume_label(l2, "TEST_FAT")
    lu.assertTrue(found_fat, "FAT32 Volume verify failed. Got label: " .. tostring(label_fat))

    -- [Feature Test: BitLocker] 验证加密状态
    print("  [10/12] Verifying BitLocker Status...")
    local bl_ntfs = win.disk.bitlocker.get_status(l1)
    lu.assertTrue(bl_ntfs == "None" or bl_ntfs == "Off", "Unexpected BitLocker status: " .. tostring(bl_ntfs))

    -- [Phase 5] 文件系统交互
    print("  [11/12] Verifying Filesystem I/O...")
    
    local function verify_io(path, name)
        local p = path .. "test_io.txt"
        local f = io.open(p, "w")
        lu.assertNotNil(f, name.." write open failed")
        f:write("hello " .. name)
        f:close()
        
        local info = win.fs.stat(p)
        lu.assertNotNil(info, name.." stat failed")
        
        local f2 = io.open(p, "r")
        local d = f2:read("*a")
        f2:close()
        lu.assertEquals(d, "hello " .. name)
    end
    
    verify_io(l1, "NTFS")
    verify_io(l2, "FAT32")

    -- [Phase 6] 销毁与清理
    print("  [12/12] Cleaning (Unmount & VDS Clean)...")
    win.disk.mount.unmount_all_on_disk(drive_index)
    self.mount_points = {} 
    
    local clean_ok, clean_err = win.disk.vds.clean(drive_index)
    lu.assertTrue(clean_ok, "VDS Clean failed: " .. tostring(clean_err))
    
    drive = win.disk.physical.open(drive_index, "r", true)
    local final_layout = win.disk.layout.get(drive)
    drive:close()
    
    lu.assertEquals(#final_layout.parts, 0, "Disk should be empty after clean")

    print("  [SUCCESS] All Disk integration tests passed.")
end