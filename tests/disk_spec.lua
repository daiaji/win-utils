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
        win.disk.vhd.detach(self.vhd_handle)
        self.vhd_handle:close()
        self.vhd_handle = nil
    end
    if win.fs and win.fs.exists(self.temp_vhd) then
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
        -- 复原：明确打印 bus type，用于人工 debug
        print(string.format("  [INFO] Disk %d: %s (Bus: %s)", d.index, d.model, tostring(d.bus)))
    end
end

-- [RESTORED STRICTNESS] 明确检查 MBR/GPT 样式
function TestDisk:test_Layout_IOCTL()
    if not self.is_admin then return end
    
    local pd = win.disk.physical.open(0, "r")
    if not pd then return end
    
    if win.disk.layout and win.disk.layout.get then
        local layout = win.disk.layout.get(pd)
        if layout then
            lu.assertIsTable(layout)
            -- 旧版逻辑：严格检查分区表样式
            lu.assertTrue(layout.style == "MBR" or layout.style == "GPT", "Unknown Disk Style: " .. tostring(layout.style))
            lu.assertIsTable(layout.parts)
        end
    end
    pd:close()
end

function TestDisk:test_VHD_Workflow()
    if not self.is_admin then print("  [SKIP] Admin required for VHD"); return end
    
    local h, err = win.disk.vhd.create(self.temp_vhd, 16 * 1024 * 1024)
    lu.assertNotNil(h, "VHD Create: " .. tostring(err))
    self.vhd_handle = h
    
    lu.assertTrue(win.disk.vhd.attach(h))
    
    local phys_path = win.disk.vhd.wait_for_physical_path(h, 5000)
    lu.assertNotNil(phys_path)
    
    local idx = tonumber(phys_path:match("PhysicalDrive(%d+)"))
    lu.assertNotNil(idx)
    
    local drive = win.disk.physical.open(idx, "rw", true)
    lu.assertNotNil(drive)
    
    local patterns = { 0xAA }
    local ok, scan_err = win.disk.surface.scan(drive, nil, "write", patterns)
    lu.assertTrue(ok, "Surface scan failed: " .. tostring(scan_err))
    
    local wipe_ok, wipe_err = drive:wipe_zero()
    lu.assertTrue(wipe_ok, wipe_err)
    
    drive:close()
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
    local ok, status = pcall(function() return win.disk.bitlocker.get_status("C:") end)
    if ok then
        lu.assertTrue(status == "Locked" or status == "None" or status == "Off")
        local unlocked = win.disk.bitlocker.is_unlocked("C:")
        lu.assertIsBoolean(unlocked)
    end
end

function TestDisk:test_Volume_List()
    local vols = win.disk.volume.list()
    lu.assertIsTable(vols)
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

function TestDisk:test_Badblocks()
    lu.assertNotNil(win.disk.surface)
    lu.assertIsFunction(win.disk.surface.scan)
end