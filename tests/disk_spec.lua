local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')
local kernel32 = require('ffi.req') 'Windows.sdk.kernel32'
local util = require('win-utils.core.util')

TestDisk = {}

function TestDisk:setUp()
    self.is_admin = win.process.token.is_elevated()
    self.temp_vhd = os.getenv("TEMP") .. "\\test_vhd_" .. os.time() .. ".vhdx"
    self.mount_points = {}
    self.vhd_handle = nil
    self.img_src = os.getenv("TEMP") .. "\\test_src_" .. os.time() .. ".img"
    self.img_dst = os.getenv("TEMP") .. "\\test_dst_" .. os.time() .. ".img"
end

function TestDisk:tearDown()
    if self.mount_points then
        for _, letter in ipairs(self.mount_points) do
            win.disk.mount.unmount(letter)
        end
    end
    if self.vhd_handle then
        win.disk.vhd.detach(self.vhd_handle)
        self.vhd_handle:close()
        self.vhd_handle = nil
    end
    local files = { self.temp_vhd, self.img_src, self.img_dst }
    for _, f in ipairs(files) do
        for i=1, 5 do
            if not win.fs.exists(f) then break end
            local ok = os.remove(f)
            if ok then break end
            kernel32.Sleep(100)
        end
    end
end

-- [Unit Tests] ... (Same as before)
function TestDisk:test_01_Physical_List()
    local drives = win.disk.physical.list()
    lu.assertIsTable(drives)
    lu.assertTrue(#drives > 0, "No physical drives found")
    print("\n  [INFO] System Drives:")
    for _, d in ipairs(drives) do
        lu.assertIsNumber(d.index)
        print(string.format("    #%d: %s (%s) - %.2f GB", d.index, d.model, d.bus, d.size/(1024^3)))
    end
end

function TestDisk:test_02_Layout_IOCTL()
    if not self.is_admin then return end
    local pd, err = win.disk.physical.open(0, "r")
    if not pd then return end
    if win.disk.layout and win.disk.layout.get then
        local layout = win.disk.layout.get(pd)
        if layout then
            lu.assertIsTable(layout)
            lu.assertTrue(layout.style == "MBR" or layout.style == "GPT")
        end
    end
    pd:close()
end

function TestDisk:test_03_BitLocker_Status()
    if not self.is_admin then return end
    local status = win.disk.bitlocker.get_status("C:")
    if status then
        lu.assertTrue(status == "Locked" or status == "None" or status == "Off")
    end
end

function TestDisk:test_04_Image_Ops()
    if not self.is_admin then return end
    local h = win.disk.vhd.create(self.temp_vhd, 4 * 1024 * 1024)
    win.disk.vhd.attach(h)
    self.vhd_handle = h
    local phys_path = win.disk.vhd.wait_for_physical_path(h)
    local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    local drive = win.disk.physical.open(idx, "rw", true)
    local img_path = os.getenv("TEMP") .. "\\test_src_" .. os.time() .. ".img"
    local f = io.open(img_path, "wb"); f:write(string.rep("A", 1024)); f:close()
    lu.assertTrue(win.disk.image.write(img_path, drive))
    local dump_path = os.getenv("TEMP") .. "\\test_dump_" .. os.time() .. ".img"
    lu.assertTrue(win.disk.image.read(drive, dump_path))
    drive:close()
    os.remove(img_path); os.remove(dump_path)
end

function TestDisk:test_05_Volume_List()
    local vols = win.disk.volume.list()
    lu.assertNotNil(vols)
    lu.assertTrue(#vols > 0)
end

function TestDisk:test_06_Surface_Scan_API()
    lu.assertNotNil(win.disk.surface)
end

-- [Integration Test]
function TestDisk:test_VHD_Integrated_Lifecycle()
    if not self.is_admin then return end
    print("\n  === Starting Integrated VHD Lifecycle Test ===")

    local h, err = win.disk.vhd.create(self.temp_vhd, 512 * 1024 * 1024)
    lu.assertNotNil(h, "VHD Create failed")
    self.vhd_handle = h
    win.disk.vhd.attach(h)
    local phys_path = win.disk.vhd.wait_for_physical_path(h, 5000)
    local drive_index = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    print(string.format("         Target: PhysicalDrive%d", drive_index))

    local drive = win.disk.physical.open(drive_index, "rw", true)
    lu.assertTrue(drive:lock(true), "Lock failed")

    print("  [3/12] Raw I/O & Surface Scan...")
    lu.assertTrue(win.disk.surface.scan(drive, function() return true end, "write", { "55", "AA" }), "Scan failed")

    print("  [5/12] Applying GPT Partition Layout...")
    drive:wipe_layout()
    local ONE_MB = 1024 * 1024
    local parts = {
        { name="EFI", gpt_type=win.disk.types.GPT.ESP, offset=1*ONE_MB, size=100*ONE_MB, attr=win.disk.types.GPT.FLAGS.NO_DRIVE_LETTER },
        { name="Data1", gpt_type=win.disk.types.GPT.DATA, offset=101*ONE_MB, size=200*ONE_MB },
        { name="Data2", gpt_type=win.disk.types.GPT.DATA, offset=302*ONE_MB, size=100*ONE_MB }
    }
    lu.assertTrue(win.disk.layout.apply(drive, "GPT", parts), "Layout apply failed")
    drive:close()

    print("  [7/12] Formatting Partitions...")
    
    local ok_fmt1, msg_fmt1 = win.disk.format.format(drive_index, 101 * ONE_MB, "NTFS", "TEST_NTFS")
    lu.assertTrue(ok_fmt1, "Format NTFS failed: " .. tostring(msg_fmt1))
    print("         NTFS Format Strategy: " .. tostring(msg_fmt1)) -- [DEBUG] Print strategy
    
    local ok_fmt2, msg_fmt2 = win.disk.format.format(drive_index, 302 * ONE_MB, "FAT32", "TEST_FAT")
    lu.assertTrue(ok_fmt2, "Format FAT32 failed: " .. tostring(msg_fmt2))
    print("         FAT32 Format Strategy: " .. tostring(msg_fmt2)) -- [DEBUG] Print strategy

    print("  [8/12] Mounting Volumes...")
    local ok_mnt1, l1 = win.disk.volume.assign(drive_index, 101 * ONE_MB)
    lu.assertTrue(ok_mnt1, "Mount NTFS failed")
    table.insert(self.mount_points, l1)
    local ok_mnt2, l2 = win.disk.volume.assign(drive_index, 302 * ONE_MB)
    lu.assertTrue(ok_mnt2, "Mount FAT32 failed")
    table.insert(self.mount_points, l2)
    
    print(string.format("         Mounted at %s and %s", l1, l2))

    print("  [9/12] Verifying Filesystem I/O...")
    
    local function verify_io(path, name)
        local p = path .. "test_io.txt"
        local native = require 'win-utils.core.native'
        local hFile, open_err
        
        for i=1, 20 do
            hFile, open_err = native.open_file(p, "w")
            if hFile then break end
            kernel32.Sleep(500)
        end
        
        if not hFile then
            local msg, code = util.last_error()
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
    end
    
    verify_io(l1, "NTFS")
    verify_io(l2, "FAT32")

    print("  [10/12] Verifying Volume List...")
    local found_l1, found_l2 = false, false
    for i=1, 15 do
        local vols = win.disk.volume.list()
        for _, v in ipairs(vols) do
            for _, mp in ipairs(v.mount_points) do
                if mp:lower():find(l1:lower(), 1, true) and v.label == "TEST_NTFS" then found_l1 = true end
                if mp:lower():find(l2:lower(), 1, true) and v.label == "TEST_FAT" then found_l2 = true end
            end
        end
        if found_l1 and found_l2 then break end
        kernel32.Sleep(500)
    end
    lu.assertTrue(found_l1, "NTFS Volume/Label check failed")

    print("  [12/12] Cleaning...")
    win.disk.mount.unmount_all_on_disk(drive_index)
    self.mount_points = {} 
    lu.assertTrue(win.disk.vds.clean(drive_index))
    print("  [SUCCESS]")
end