local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local kernel32 = require('ffi.req') 'Windows.sdk.kernel32'
local util = require('win-utils.core.util') -- [FIX] Added missing require

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

function TestDisk:test_05_Volume_List()
    local vols, err = win.disk.volume.list()
    lu.assertNotNil(vols, "Vol list failed: " .. tostring(err))
    lu.assertTrue(#vols > 0)
    
    local found_c = false
    for _, v in ipairs(vols) do
        lu.assertIsString(v.guid_path)
        -- 打印信息以便调试
        -- print("  Volume: " .. v.guid_path .. " (" .. (v.label or "") .. ")")
        for _, mp in ipairs(v.mount_points) do
            if mp:match("^[Cc]:") then found_c = true end
        end
    end
    lu.assertTrue(found_c, "C: drive volume should be listed")
end

function TestDisk:test_06_Surface_Scan_API()
    -- 验证 API 存在性及基本调用（不进行实际长时间扫描）
    lu.assertNotNil(win.disk.surface)
    lu.assertIsFunction(win.disk.surface.scan)
    
    -- 如果有管理员权限，对 VHD 进行一个微小的扫描测试
    if self.is_admin then
        local h = win.disk.vhd.create(self.temp_vhd, 4 * 1024 * 1024)
        win.disk.vhd.attach(h)
        self.vhd_handle = h
        
        local phys_path = win.disk.vhd.wait_for_physical_path(h)
        local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
        local drive = win.disk.physical.open(idx, "rw", true)
        
        local ok, msg = win.disk.surface.scan(drive, nil, "write", {0x55})
        lu.assertTrue(ok, "Surface scan API test failed: " .. tostring(msg))
        
        drive:close()
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
    local h, err = win.disk.vhd.create(self.temp_vhd, 512 * 1024 * 1024)
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
            -- VHD 大小通常精确，或者按扇区对齐
            lu.assertTrue(d.size >= 510 * 1024 * 1024) 
            -- print(string.format("         Found in list: %s (%s)", d.model, d.bus))
        end
    end
    lu.assertTrue(found_in_list, "Created VHD not found in win.disk.physical.list()")

    -- [Phase 2] 裸机操作 (Raw I/O)
    local drive = win.disk.physical.open(drive_index, "rw", true)
    lu.assertNotNil(drive, "Open drive failed")
    lu.assertTrue(drive:lock(true), "Lock failed")

    -- [Feature Test: Image Ops] 镜像读写测试 (覆盖 test_04_Image_Ops)
    print("  [3/12] Testing Image Write/Read...")
    local f = io.open(self.img_src, "wb")
    local pattern = "WIN_UTILS_TEST_PATTERN"
    for i=1, 1024 do f:write(string.rep(pattern, 4)) end -- ~90KB data
    f:close()
    
    -- 写入镜像到磁盘开头
    local w_ok, w_err = win.disk.image.write(self.img_src, drive)
    lu.assertTrue(w_ok, "Image write failed: " .. tostring(w_err))
    
    -- 从磁盘读回镜像
    local r_ok, r_err = win.disk.image.read(drive, self.img_dst)
    lu.assertTrue(r_ok, "Image read failed: " .. tostring(r_err))
    
    -- 验证内容一致性
    local f1 = io.open(self.img_src, "rb"); local s1 = f1:read(1024)
    local f2 = io.open(self.img_dst, "rb"); local s2 = f2:read(1024)
    f1:close(); f2:close()
    lu.assertEquals(s1, s2, "Image verify failed")

    -- [Feature Test: Surface Scan] 表面扫描测试 (覆盖 test_06 & Badblocks)
    print("  [4/12] Running Surface Scan (Write Mode)...")
    local scan_ok, scan_msg = win.disk.surface.scan(drive, function(p) return true end, "write", { 0x55, 0xAA })
    lu.assertTrue(scan_ok, "Surface scan failed: " .. tostring(scan_msg))

    -- [Phase 3] 分区管理
    print("  [5/12] Applying GPT Partition Layout...")
    drive:wipe_layout() -- 清除之前的镜像测试数据
    
    local ONE_MB = 1024 * 1024
    local parts = {
        -- Partition 1: ESP
        { 
            name = "EFI System",
            gpt_type = win.disk.types.GPT.ESP,
            offset = 1 * ONE_MB,
            size = 100 * ONE_MB,
            attr = win.disk.types.GPT.FLAGS.NO_DRIVE_LETTER
        },
        -- Partition 2: NTFS Data
        {
            name = "Data NTFS",
            gpt_type = win.disk.types.GPT.DATA,
            offset = 101 * ONE_MB,
            size = 200 * ONE_MB
        },
        -- Partition 3: FAT32 Data
        {
            name = "Data FAT32",
            gpt_type = win.disk.types.GPT.DATA,
            offset = 302 * ONE_MB, 
            size = 100 * ONE_MB
        }
    }
    
    local layout_ok, layout_err = win.disk.layout.apply(drive, "GPT", parts)
    lu.assertTrue(layout_ok, "Layout apply failed: " .. tostring(layout_err))

    -- [Feature Test: Layout IOCTL] 验证写入的分区表 (覆盖 test_02)
    print("  [6/12] Verifying Partition Layout...")
    local layout = win.disk.layout.get(drive)
    lu.assertNotNil(layout, "Layout get failed")
    lu.assertEquals(layout.style, "GPT")
    lu.assertEquals(#layout.parts, 3)
    -- 验证分区偏移和大小
    lu.assertEquals(layout.parts[2].off, 101 * ONE_MB)
    lu.assertEquals(layout.parts[3].len, 100 * ONE_MB)

    drive:close() -- 关闭句柄以允许系统刷新卷

    -- [Phase 4] 卷管理与格式化
    print("  [7/12] Formatting Partitions (NTFS & FAT32)...")
    
    -- Format NTFS (Partition 2)
    local ok_fmt1, err_fmt1 = win.disk.format.format(drive_index, 101 * ONE_MB, "NTFS", "TEST_NTFS")
    lu.assertTrue(ok_fmt1, "Format NTFS failed: " .. tostring(err_fmt1))
    
    -- Format FAT32 (Partition 3)
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

    -- [Phase 5] 文件系统交互 (Moved UP to force FS mount)
    print("  [9/12] Verifying Filesystem I/O (Forces Mount)...")
    
    local function verify_io(path, name)
        local p = path .. "test_io.txt"
        
        -- [CRITICAL] 使用 Native API 绕过 CRT 的缓存/状态检查
        local native = require 'win-utils.core.native'
        local hFile, open_err
        
        -- Retry loop for device readiness
        for i=1, 20 do
            -- Generic Read/Write, Shared Read/Write
            hFile, open_err = native.open_file(p, "w")
            if hFile then break end
            kernel32.Sleep(500)
        end
        
        if not hFile then
            local msg, code = util.last_error()
            -- [ERROR_CONTEXT] util needs to be required at top
            error(string.format("%s native open failed: %s (%d) - Raw Err: %s", name, msg, code, tostring(open_err)))
        end
        
        local data = "hello " .. name
        local written = ffi.new("DWORD[1]")
        local buf = ffi.cast("const void*", data)
        
        if kernel32.WriteFile(hFile:get(), buf, #data, written, nil) == 0 then
            local _, code = util.last_error()
            hFile:close()
            error(string.format("%s WriteFile failed: error %d", name, code))
        end
        hFile:close()
        
        lu.assertEquals(written[0], #data, name .. " write partial")
        
        local info = win.fs.stat(p)
        lu.assertNotNil(info, name.." stat failed")
        
        local f2 = io.open(p, "r")
        local d = f2:read("*a")
        f2:close()
        lu.assertEquals(d, data)
    end
    
    verify_io(l1, "NTFS")
    verify_io(l2, "FAT32")

    -- [Feature Test: Volume List] 验证卷列表 (覆盖 test_05)
    print("  [10/12] Verifying Volume List & Labels...")
    
    local found_l1, found_l2 = false, false
    
    -- Retry loop for metadata consistency
    for i=1, 15 do
        local vols = win.disk.volume.list()
        found_l1, found_l2 = false, false
        
        for _, v in ipairs(vols) do
            for _, mp in ipairs(v.mount_points) do
                if mp:lower():find(l1:lower(), 1, true) then 
                    if v.label == "TEST_NTFS" then found_l1 = true end
                end
                if mp:lower():find(l2:lower(), 1, true) then 
                    if v.label == "TEST_FAT" then found_l2 = true end
                end
            end
        end
        
        if found_l1 and found_l2 then break end
        
        if i == 15 then
            print(string.format("    Debug: Retry %d failed. Found NTFS=%s, FAT=%s", i, tostring(found_l1), tostring(found_l2)))
        end
        kernel32.Sleep(500)
    end
    
    lu.assertTrue(found_l1, "NTFS Volume not found or label mismatch")
    lu.assertTrue(found_l2, "FAT32 Volume not found or label mismatch")

    -- [Feature Test: BitLocker] 验证加密状态 (覆盖 test_03)
    print("  [11/12] Verifying BitLocker Status...")
    local bl_ntfs = win.disk.bitlocker.get_status(l1)
    lu.assertTrue(bl_ntfs == "None" or bl_ntfs == "Off", "Unexpected BitLocker status: " .. tostring(bl_ntfs))

    -- [Phase 6] 销毁与清理
    print("  [12/12] Cleaning (Unmount & VDS Clean)...")
    win.disk.mount.unmount_all_on_disk(drive_index)
    self.mount_points = {} -- 已手动清理
    
    -- VDS Clean 测试
    local clean_ok, clean_err = win.disk.vds.clean(drive_index)
    lu.assertTrue(clean_ok, "VDS Clean failed: " .. tostring(clean_err))
    
    -- 最终验证：磁盘应该是空的
    drive = win.disk.physical.open(drive_index, "r", true)
    local final_layout = win.disk.layout.get(drive)
    drive:close()
    
    lu.assertEquals(#final_layout.parts, 0, "Disk should be empty after clean")

    print("  [SUCCESS] All Disk integration tests passed.")
end