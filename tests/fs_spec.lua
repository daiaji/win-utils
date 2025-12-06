local lu = require('luaunit')
local win = require('win-utils')
local ffi = require('ffi')

TestFS = {}

function TestFS:setUp()
    self.sandbox = os.getenv("TEMP") .. "\\test_fs_sandbox_" .. os.time()
    win.fs.mkdir(self.sandbox)
end

function TestFS:tearDown()
    if win.fs.exists(self.sandbox) then
        win.fs.delete(self.sandbox)
    end
end

function TestFS:test_Path_Conversion()
    local path_mod = require('win-utils.fs.path')
    local nt = "\\??\\C:\\Windows"
    local dos = path_mod.nt_path_to_dos(nt)
    if dos then
        lu.assertStrContains(dos, "Windows")
        lu.assertStrContains(dos, ":")
    else
        print("[INFO] Path conversion returned nil (Non-standard drive map?)")
    end
end

function TestFS:test_Mkdir_Recursive()
    local p = self.sandbox .. "\\a\\b\\c"
    local ok, err = win.fs.mkdir(p, {p=true})
    lu.assertTrue(ok, "Mkdir failed: " .. tostring(err))
    lu.assertTrue(win.fs.is_dir(p))
    lu.assertTrue(win.fs.is_dir(self.sandbox .. "\\a"))
end

function TestFS:test_Recursive_Ops_And_ReadOnly()
    local src = self.sandbox .. "\\src"
    local dst = self.sandbox .. "\\dst"
    
    local mk_ok, mk_err = win.fs.mkdir(src .. "\\sub", {p=true})
    lu.assertTrue(mk_ok, "Mkdir failed: " .. tostring(mk_err))
    
    local file_path = src .. "\\sub\\file.txt"
    local f, io_err = io.open(file_path, "w")
    lu.assertNotNil(f, "io.open failed: " .. tostring(io_err))
    f:write("content")
    f:close()
    
    -- 1. Copy
    local cp_ok, cp_err = win.fs.copy(src, dst)
    lu.assertTrue(cp_ok, "Copy failed: " .. tostring(cp_err))
    lu.assertTrue(win.fs.is_dir(dst .. "\\sub"))
    lu.assertTrue(win.fs.exists(dst .. "\\sub\\file.txt"))
    
    -- 2. Read-Only
    local raw = require('win-utils.fs.raw')
    if raw.set_attributes then
        local att_ok, att_err = raw.set_attributes(file_path, 1) -- READONLY
        lu.assertTrue(att_ok, "Set attributes failed: " .. tostring(att_err))
    end
    
    -- 3. Delete
    local ok_del, err_del = win.fs.delete(src)
    lu.assertTrue(ok_del, "Recursive delete failed: " .. tostring(err_del))
    lu.assertFalse(win.fs.exists(src))
end

function TestFS:test_Move()
    local src = self.sandbox .. "\\move_src.txt"
    local dst = self.sandbox .. "\\move_dst.txt"
    local f = io.open(src, "w"); f:write("data"); f:close()
    
    local ok, err = win.fs.move(src, dst)
    lu.assertTrue(ok, "Move failed: " .. tostring(err))
    lu.assertFalse(win.fs.exists(src))
    lu.assertTrue(win.fs.exists(dst))
end

function TestFS:test_Link_Junction()
    local target = self.sandbox .. "\\target_dir"
    local link = self.sandbox .. "\\link_dir"
    win.fs.mkdir(target)
    
    local ok, err = win.fs.link(target, link)
    if not ok then
        print("  [SKIP] Link failed: " .. tostring(err))
    else
        lu.assertTrue(win.fs.is_link(link))
        lu.assertTrue(win.fs.is_dir(link))
        
        local ntfs = require('win-utils.fs.ntfs')
        local read_target, type = ntfs.read_link(link)
        lu.assertNotNil(read_target)
        lu.assertTrue(type == "Junction" or type == "Symlink")
    end
end

function TestFS:test_Stats_Usage()
    local d1 = self.sandbox .. "\\du_dir"
    win.fs.mkdir(d1)
    local f = io.open(d1 .. "\\1.bin", "wb"); f:write(string.rep("\0", 10240)); f:close()
    
    local usage = win.fs.get_usage_info(d1)
    lu.assertEquals(usage.files, 1)
    lu.assertTrue(usage.size >= 10240)
    
    local space = win.fs.get_space_info(self.sandbox)
    lu.assertTrue(space.total_bytes > 0)
    
    local st = win.fs.stat(d1 .. "\\1.bin")
    lu.assertEquals(st.size, 10240)
end

function TestFS:test_Wipe()
    local p = self.sandbox .. "\\secret.txt"
    local f = io.open(p, "w"); f:write("secret"); f:close()
    
    local ok, err = win.fs.wipe(p, {passes=1})
    lu.assertTrue(ok, "Wipe failed: " .. tostring(err))
    lu.assertFalse(win.fs.exists(p))
end

function TestFS:test_Timestamps()
    local p = self.sandbox .. "\\time.txt"
    local f = io.open(p, "w"); f:write("t"); f:close()
    local ok, err = win.fs.update_timestamps(p)
    lu.assertTrue(ok, "Touch failed: " .. tostring(err))
end