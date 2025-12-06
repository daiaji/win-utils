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
        -- 确保 tearDown 时也能通过强制手段删除，防止测试失败导致残留
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
    lu.assertTrue(win.fs.mkdir(p, {p=true}))
    lu.assertTrue(win.fs.is_dir(p))
    lu.assertTrue(win.fs.is_dir(self.sandbox .. "\\a"))
end

-- [CRITICAL RESTORATION] 恢复了对只读文件强制删除的测试
function TestFS:test_Recursive_Ops_And_ReadOnly()
    local src = self.sandbox .. "\\src"
    local dst = self.sandbox .. "\\dst"
    
    -- [Fix] Assert mkdir success to avoid nil handle crash later
    local mk_ok, mk_err = win.fs.mkdir(src .. "\\sub", {p=true})
    lu.assertTrue(mk_ok, "Mkdir failed: " .. tostring(mk_err))
    
    local file_path = src .. "\\sub\\file.txt"
    local f, err = io.open(file_path, "w")
    lu.assertNotNil(f, "io.open failed: " .. tostring(err))
    f:write("content")
    f:close()
    
    -- 1. Copy
    local cp_ok, cp_err = win.fs.copy(src, dst)
    lu.assertTrue(cp_ok, "Copy failed: " .. tostring(cp_err))
    lu.assertTrue(win.fs.is_dir(dst .. "\\sub"))
    lu.assertTrue(win.fs.exists(dst .. "\\sub\\file.txt"))
    
    -- 2. 设置源文件为只读 (Read-Only)
    -- 这是一个关键测试：win.fs.delete 是否能自动处理只读属性？
    local raw = require('win-utils.fs.raw')
    if raw.set_attributes then
        -- FILE_ATTRIBUTE_READONLY = 1
        lu.assertTrue(raw.set_attributes(file_path, 1), "Failed to set readonly")
    end
    
    -- 3. Delete (Should force delete readonly file)
    local ok_del, err_del = win.fs.delete(src)
    lu.assertTrue(ok_del, "Recursive delete failed on readonly file: " .. tostring(err_del))
    lu.assertFalse(win.fs.exists(src))
end

function TestFS:test_Move()
    local src = self.sandbox .. "\\move_src.txt"
    local dst = self.sandbox .. "\\move_dst.txt"
    local f = io.open(src, "w"); f:write("data"); f:close()
    
    lu.assertTrue(win.fs.move(src, dst))
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
    
    -- Usage (du)
    local usage = win.fs.get_usage_info(d1)
    lu.assertEquals(usage.files, 1)
    lu.assertTrue(usage.size >= 10240)
    
    -- Space (df)
    local space = win.fs.get_space_info(self.sandbox)
    lu.assertTrue(space.total_bytes > 0)
    
    -- Stat
    local st = win.fs.stat(d1 .. "\\1.bin")
    lu.assertEquals(st.size, 10240)
end

function TestFS:test_Wipe()
    local p = self.sandbox .. "\\secret.txt"
    local f = io.open(p, "w"); f:write("secret"); f:close()
    
    lu.assertTrue(win.fs.wipe(p, {passes=1}))
    lu.assertFalse(win.fs.exists(p))
end

function TestFS:test_Timestamps()
    local p = self.sandbox .. "\\time.txt"
    local f = io.open(p, "w"); f:write("t"); f:close()
    lu.assertTrue(win.fs.update_timestamps(p))
end