local ffi = require 'ffi'
local bit = require 'bit' -- LuaJIT
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local class = require 'win-utils.deps'.class

local RegKey = class()

function RegKey:init(hkey) self.hkey = hkey end

function RegKey:close()
    if self.hkey then 
        advapi32.RegCloseKey(self.hkey)
        self.hkey = nil 
    end
end

-- [Helper] 将 Lua 表转为 REG_MULTI_SZ 缓冲区
local function table_to_multisz(tbl)
    local parts = {}
    local total_len = 0
    for _, s in ipairs(tbl) do
        local w = util.to_wide(s)
        -- 计算 wchar_t 长度 (包括 null)
        local len = 0; while w[len] ~= 0 do len=len+1 end; len=len+1
        table.insert(parts, {ptr=w, bytes=len*2})
        total_len = total_len + len*2
    end
    total_len = total_len + 2 -- 结尾的双 null
    
    local buf = ffi.new("uint8_t[?]", total_len)
    local offset = 0
    for _, item in ipairs(parts) do
        ffi.copy(buf + offset, item.ptr, item.bytes)
        offset = offset + item.bytes
    end
    -- 最后两字节自动为0 (ffi.new 已清零)
    return buf, total_len
end

function RegKey:read(name, opts)
    local wname = util.to_wide(name)
    local type_ptr = ffi.new("DWORD[1]")
    local size_ptr = ffi.new("DWORD[1]")
    
    if advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, nil, size_ptr) ~= 0 then return nil end
    
    local buf = ffi.new("uint8_t[?]", size_ptr[0])
    if advapi32.RegQueryValueExW(self.hkey, wname, nil, type_ptr, buf, size_ptr) ~= 0 then return nil end
    
    local t = type_ptr[0]
    
    -- REG_SZ / REG_EXPAND_SZ
    if t == 1 or t == 2 then 
        local str = util.from_wide(ffi.cast("wchar_t*", buf))
        if str then str = str:gsub("%z+$", "") end -- Trim trailing nulls
        
        if t == 2 and (not opts or opts.expand ~= false) then
            local wstr = util.to_wide(str)
            local needed = kernel32.ExpandEnvironmentStringsW(wstr, nil, 0)
            if needed > 0 then
                local ex = ffi.new("wchar_t[?]", needed)
                kernel32.ExpandEnvironmentStringsW(wstr, ex, needed)
                str = util.from_wide(ex):gsub("%z+$", "")
            end
        end
        return str
    
    -- REG_DWORD
    elseif t == 4 then 
        return ffi.cast("DWORD*", buf)[0]
    
    -- REG_QWORD
    elseif t == 11 then 
        return tonumber(ffi.cast("uint64_t*", buf)[0])
        
    -- REG_MULTI_SZ
    elseif t == 7 then 
        local res = {}
        local ptr = ffi.cast("wchar_t*", buf)
        local offset = 0
        local max_bytes = size_ptr[0]
        
        while offset * 2 < max_bytes do
            local s = util.from_wide(ptr + offset)
            if not s or s == "" then break end
            table.insert(res, s)
            -- 移动指针: 字符串长度 + null
            offset = offset + #s + 1
            -- 处理连续的 null (防守性编程)
            while offset * 2 < max_bytes and (ptr+offset)[0] == 0 do 
                break -- MultiSZ 结束
            end
        end
        return res
        
    -- REG_BINARY
    elseif t == 3 then 
        return ffi.string(buf, size_ptr[0])
    end
    
    return nil
end

function RegKey:write(name, val, type_str)
    local wname = util.to_wide(name)
    local data, size, code
    
    -- 自动类型推断
    if not type_str then
        if type(val) == "number" then type_str = "dword"
        elseif type(val) == "table" then type_str = "multi_sz"
        else type_str = "string" end
    end
    
    local gc_anchor
    
    if type_str == "dword" then
        local d = ffi.new("DWORD[1]", val)
        data = ffi.cast("uint8_t*", d); size = 4; code = 4; gc_anchor = d
    elseif type_str == "qword" then
        local q = ffi.new("uint64_t[1]", val)
        data = ffi.cast("uint8_t*", q); size = 8; code = 11; gc_anchor = q
    elseif type_str == "string" or type_str == "expand_sz" then
        local w = util.to_wide(tostring(val))
        data = ffi.cast("uint8_t*", w); size = (#tostring(val)+1)*2; 
        code = (type_str == "expand_sz") and 2 or 1
        gc_anchor = w
    elseif type_str == "multi_sz" and type(val) == "table" then
        data, size = table_to_multisz(val)
        code = 7
    elseif type_str == "binary" then
        data = ffi.cast("uint8_t*", val)
        size = #val
        code = 3
    else
        return false, "Unsupported type"
    end
    
    return advapi32.RegSetValueExW(self.hkey, wname, 0, code, data, size) == 0
end

function RegKey:delete_value(name) 
    return advapi32.RegDeleteValueW(self.hkey, util.to_wide(name)) == 0 
end

local M = {}

function M.open_key(root, sub)
    local roots = { HKLM=0x80000002, HKCU=0x80000001, HKU=0x80000003 }
    local hKey = ffi.new("HKEY[1]")
    local wsub = util.to_wide(sub)
    
    -- KEY_ALL_ACCESS = 0xF003F
    if advapi32.RegCreateKeyExW(ffi.cast("HKEY", roots[root] or roots.HKLM), wsub, 0, nil, 0, 0xF003F, nil, hKey, nil) ~= 0 then 
        return nil 
    end
    return RegKey(hKey[0])
end

function M.delete_key(root, sub, rec)
    local roots = { HKLM=0x80000002, HKCU=0x80000001, HKU=0x80000003 }
    local h = ffi.cast("HKEY", roots[root] or roots.HKLM)
    local w = util.to_wide(sub)
    if rec then 
        return advapi32.RegDeleteTreeW(h, w) == 0 
    else 
        return advapi32.RegDeleteKeyW(h, w) == 0 
    end
end

function M.save_hive(key, path)
    token.enable_privilege("SeBackupPrivilege")
    -- 必须独占写入 (share_mode = exclusive)
    local hFile = native.open_file(path, "w", "exclusive")
    if not hFile then return false end
    
    local res = ntdll.NtSaveKey(key.hkey, hFile:get())
    hFile:close()
    return res >= 0
end

function M.load_hive(key_path, file_path)
    token.enable_privilege("SeRestorePrivilege")
    
    -- [GC SAFETY] 使用 init_object_attributes 获取 anchor
    local oa_k, anchor1 = native.init_object_attributes(key_path)
    local oa_f, anchor2 = native.init_object_attributes(native.dos_path_to_nt_path(file_path))
    
    local res = ntdll.NtLoadKey(oa_k, oa_f)
    
    -- 保持 anchor 存活直到调用结束
    local _ = {anchor1, anchor2}
    return res == 0
end

function M.unload_hive(key_path)
    token.enable_privilege("SeRestorePrivilege")
    local oa_k, anchor = native.init_object_attributes(key_path)
    local res = ntdll.NtUnloadKey(oa_k)
    local _ = anchor
    return res == 0
end

-- [Modern LuaJIT] 使用 xpcall + goto 处理资源清理
function M.with_hive(key_path, file_path, func)
    local loaded = M.load_hive(key_path, file_path)
    if not loaded then return false, "Load hive failed" end
    
    local result_ok, result_val
    local func_ok, err = xpcall(function()
        return func(key_path)
    end, debug.traceback)
    
    if not func_ok then
        print("Error in with_hive block: " .. tostring(err))
        result_ok = false
        result_val = err
    else
        result_ok = true
        result_val = func_ok -- func 的返回值
    end
    
    -- 强制 GC，关闭任何可能打开的 Key Handle，否则 Unload 会失败
    collectgarbage(); collectgarbage()
    
    -- 清理逻辑
    local attempts = 0
    ::retry_unload::
    if not M.unload_hive(key_path) then
        attempts = attempts + 1
        if attempts < 3 then
            kernel32.Sleep(100)
            collectgarbage()
            goto retry_unload
        end
        -- 如果卸载失败，且业务逻辑成功，依然返回失败（资源泄漏）
        return false, "Unload hive failed (Hive locked?)"
    end
    
    if not result_ok then error(result_val) end
    return true, result_val
end

return M