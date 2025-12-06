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

    -- 3. 清理文件 (带重试，防止系统短暂占用)
    for i=1, 5 do
        if not win.fs.exists(self.temp_vhd) then break end
        local ok, err = os.remove(self.temp_vhd)
        if ok then break end
        kernel32.Sleep(200)
    end
end

-- =============================================================================
-- [Unit Tests] 基础组件测试
-- =============================================================================

function TestDisk:test_01_Physical_List()
    local drives = win.disk.physical.list()
    lu.assertIsTable(drives)
    -- 系统中至少应该有一个磁盘
    lu.assertTrue(#drives > 0, "No physical drives found")
    
    print("\n  [INFO] System Drives:")
    for _, d in ipairs(drives) do
        lu.assertIsNumber(d.index)
        lu.assertIsNumber(d.size)
        print(string.format("    #%d: %s (%s) - %.2f GB", 
            d.index, d.model, d.bus, d.size/(1024^3)))
    end
end

function TestDisk:test_02_Layout_IOCTL()
    if not self.is_admin then return end
    
    -- 尝试读取 0 号磁盘的布局信息（通常是系统盘）
    local pd, err = win.disk.physical.open(0, "r")
    if not pd then 
        print("  [WARN] Cannot open Disk 0: " .. tostring(err))
        return 
    end
    
    if win.disk.layout and win.disk.layout.get then
        local layout, l_err = win.disk.layout.get(pd)
        if layout then
            lu.assertIsTable(layout)
            lu.assertTrue(layout.style == "MBR" or layout.style == "GPT", "Unknown Disk Style")
            lu.assertIsTable(layout.parts)
            print("  [INFO] Disk 0 Style: " .. layout.style)
        else
            print("  [WARN] GetLayout failed: " .. tostring(l_err))
        end
    end
    pd:close()
end

function TestDisk:test_03_BitLocker_Status()
    if not self.is_admin then return end
    local status, err = win.disk.bitlocker.get_status("C:")
    if status then
        print("  [INFO] C: BitLocker Status: " .. status)
        lu.assertTrue(status == "Locked" or status == "None" or status == "Off")
    else
        print("  [WARN] BitLocker check failed (VM/Legacy?): " .. tostring(err))
    end
end

function TestDisk:test_04_Image_Ops()
    if not self.is_admin then return end
    
    -- 创建一个小 VHD 用于镜像测试
    local h = win.disk.vhd.create(self.temp_vhd, 4 * 1024 * 1024)
    win.disk.vhd.attach(h)
    self.vhd_handle = h
    
    local phys_path = win.disk.vhd.wait_for_physical_path(h)
    local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    local drive = win.disk.physical.open(idx, "rw", true)
    
    -- 生成测试源文件
    local img_path = os.getenv("TEMP") .. "\\test_src_" .. os.time() .. ".img"
    local f = io.open(img_path, "wb")
    local pattern = "LUA_WIN_UTILS_TEST"
    for i=1, 1024 do f:write(string.rep(pattern, 64)) end 
    f:close()
    
    -- 写入镜像
    local w_ok, w_err = win.disk.image.write(img_path, drive)
    lu.assertTrue(w_ok, "Image write failed: " .. tostring(w_err))
    
    -- 读回镜像
    local dump_path = os.getenv("TEMP") .. "\\test_dump_" .. os.time() .. ".img"
    local r_ok, r_err = win.disk.image.read(drive, dump_path)
    lu.assertTrue(r_ok, "Image read failed: " .. tostring(r_err))
    
    drive:close()
    
    -- 比对
    local f1 = io.open(img_path, "rb")
    local f2 = io.open(dump_path, "rb")
    local s1 = f1:read(1024)
    local s2 = f2:read(1024)
    f1:close(); f2:close()
    
    lu.assertEquals(s1, s2)
    os.remove(img_path)
    os.remove(dump_path)
end

-- =============================================================================
-- [Integration Test] VHD 全链路测试
-- =============================================================================

function TestDisk:test_99_VHD_Full_Chain()
    if not self.is_admin then 
        print("  [SKIP] Administrator privileges required for VHD Full Chain test")
        return 
    end

    print("\n  === Starting VHD Full Chain Test ===")

    -- [Step 1] 创建 VHDX
    print("  [1/9] Creating VHDX (512MB)...")
    local h, err = win.disk.vhd.create(self.temp_vhd, 512 * 1024 * 1024)
    lu.assertNotNil(h, "VHD Create failed: " .. tostring(err))
    self.vhd_handle = h

    -- [Step 2] 挂载 VHD
    print("  [2/9] Attaching VHD...")
    local ok_att, err_att = win.disk.vhd.attach(h)
    lu.assertTrue(ok_att, "Attach failed: " .. tostring(err_att))

    -- [Step 3] 获取物理路径和索引
    local phys_path = win.disk.vhd.wait_for_physical_path(h, 5000)
    lu.assertNotNil(phys_path, "Timeout resolving physical path")
    local drive_index = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    lu.assertNotNil(drive_index, "Could not parse drive index")
    print(string.format("        Target: PhysicalDrive%d", drive_index))

    -- [Step 4] 打开物理驱动器 & 锁定
    local drive, open_err = win.disk.physical.open(drive_index, "rw", true)
    lu.assertNotNil(drive, "Open PhysicalDrive failed: " .. tostring(open_err))
    
    local locked, lock_err = drive:lock(true)
    lu.assertTrue(locked, "Lock failed: " .. tostring(lock_err))

    -- [Step 5] 裸机 I/O 验证 & 表面扫描
    print("  [3/9] Raw I/O & Surface Scan...")
    
    -- A. 简单扇区读写验证
    local sector_0 = drive:read(0, 512)
    lu.assertNotNil(sector_0, "Read sector 0 failed")
    lu.assertEquals(#sector_0, 512)
    
    -- B. 表面扫描 (Badblocks 模拟)
    -- 对前 10MB 进行 0x55, 0xAA 图案读写测试
    -- 这验证了底层 win.disk.surface 模块和 IOCTL 读写逻辑
    local scan_ok, scan_msg = win.disk.surface.scan(drive, function(p) return true end, "write", { 0x55, 0xAA })
    lu.assertTrue(scan_ok, "Surface scan failed: " .. tostring(scan_msg))

    -- [Step 6] 创建分区表 (GPT)
    print("  [4/9] Partitioning (GPT: ESP + NTFS + FAT32)...")
    drive:wipe_layout() -- 确保干净
    
    local ONE_MB = 1024 * 1024
    local parts = {
        -- Partition 1: ESP (100MB)
        { 
            name = "EFI System",
            gpt_type = win.disk.types.GPT.ESP,
            offset = 1 * ONE_MB,
            size = 100 * ONE_MB,
            attr = win.disk.types.GPT.FLAGS.NO_DRIVE_LETTER
        },
        -- Partition 2: NTFS Data (200MB)
        {
            name = "Data NTFS",
            gpt_type = win.disk.types.GPT.DATA,
            offset = 101 * ONE_MB,
            size = 200 * ONE_MB
        },
        -- Partition 3: FAT32 Data (100MB)
        {
            name = "Data FAT32",
            gpt_type = win.disk.types.GPT.DATA,
            offset = 302 * ONE_MB, -- 101 + 200 + 1 (gap)
            size = 100 * ONE_MB
        }
    }
    
    local layout_ok, layout_err = win.disk.layout.apply(drive, "GPT", parts)
    lu.assertTrue(layout_ok, "Layout apply failed: " .. tostring(layout_err))
    
    -- 验证分区表是否真的写入了
    local verify_layout = win.disk.layout.get(drive)
    lu.assertEquals(#verify_layout.parts, 3, "Partition count mismatch after apply")
    lu.assertEquals(verify_layout.style, "GPT")

    -- 关闭句柄，让系统刷新分区并创建卷设备
    drive:close()
    
    -- 等待 PnP 识别
    print("        Waiting for PnP volume arrival...")
    kernel32.Sleep(2000)

    -- [Step 7] 格式化 (VDS Automation)
    print("  [5/9] Formatting Partitions...")
    
    -- Format NTFS (Partition 2)
    local ok_fmt1, err_fmt1 = win.disk.format.format(drive_index, 101 * ONE_MB, "NTFS", "TEST_NTFS")
    lu.assertTrue(ok_fmt1, "Format NTFS failed: " .. tostring(err_fmt1))
    
    -- Format FAT32 (Partition 3)
    local ok_fmt2, err_fmt2 = win.disk.format.format(drive_index, 302 * ONE_MB, "FAT32", "TEST_FAT")
    lu.assertTrue(ok_fmt2, "Format FAT32 failed: " .. tostring(err_fmt2))

    -- [Step 8] 挂载卷 (Mounting)
    print("  [6/9] Mounting Volumes...")
    
    local ok_mnt1, drive_letter_1 = win.disk.volume.assign(drive_index, 101 * ONE_MB)
    lu.assertTrue(ok_mnt1, "Mount NTFS failed: " .. tostring(drive_letter_1))
    table.insert(self.mount_points, drive_letter_1)
    
    local ok_mnt2, drive_letter_2 = win.disk.volume.assign(drive_index, 302 * ONE_MB)
    lu.assertTrue(ok_mnt2, "Mount FAT32 failed: " .. tostring(drive_letter_2))
    table.insert(self.mount_points, drive_letter_2)
    
    print(string.format("        NTFS mounted at %s", drive_letter_1))
    print(string.format("        FAT32 mounted at %s", drive_letter_2))

    -- [Step 9] 文件系统读写验证 (FS I/O)
    print("  [7/9] Verifying Filesystem I/O...")
    
    local function verify_fs(path, fs_name)
        local f_path = path .. "test.txt"
        local content = "Content for " .. fs_name
        
        -- Write
        local f, err = io.open(f_path, "w")
        lu.assertNotNil(f, fs_name .. " write open failed: " .. tostring(err))
        f:write(content)
        f:close()
        
        -- Stat
        local info = win.fs.stat(f_path)
        lu.assertNotNil(info, fs_name .. " stat failed")
        lu.assertEquals(info.size, #content)
        
        -- Read
        local f2 = io.open(f_path, "r")
        lu.assertNotNil(f2, fs_name .. " read open failed")
        local data = f2:read("*a")
        f2:close()
        
        lu.assertEquals(data, content, fs_name .. " content mismatch")
    end
    
    verify_fs(drive_letter_1, "NTFS")
    verify_fs(drive_letter_2, "FAT32")

    -- [Step 10] 清理测试 (VDS Clean)
    print("  [8/9] VDS Cleanup Verification...")
    -- 卸载卷
    win.disk.mount.unmount_all_on_disk(drive_index)
    self.mount_points = {} -- 已手动清理
    
    -- VDS Clean (抹除分区表)
    local clean_ok, clean_err = win.disk.vds.clean(drive_index)
    lu.assertTrue(clean_ok, "VDS Clean failed: " .. tostring(clean_err))
    
    -- 验证已变为空盘 (RAW/Empty MBR)
    drive = win.disk.physical.open(drive_index, "r", true)
    local final_layout = win.disk.layout.get(drive)
    drive:close()
    
    lu.assertEquals(#final_layout.parts, 0, "Disk should be empty after clean")

    print("  [9/9] Success.")
end