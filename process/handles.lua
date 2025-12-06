local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'
local table_new = require 'table.new'
local table_ext = require 'ext.table'

local M = {}

-- 列出指定进程的句柄
function M.list(pid)
    local access = 0x0400 -- PROCESS_QUERY_INFORMATION
    local h = kernel32.OpenProcess(access, false, pid)
    if not h then return nil, util.last_error() end
    
    local buf, err = native.query_variable_size(ntdll.NtQueryInformationProcess, h, 51, 4096)
    if not buf then 
        kernel32.CloseHandle(h)
        return nil, "Query Handles Failed: " .. tostring(err)
    end
    
    local info = ffi.cast("PROCESS_HANDLE_SNAPSHOT_INFORMATION*", buf)
    local res = {}
    local count = tonumber(info.NumberOfHandles)
    
    for i=0, count-1 do
        table.insert(res, { val = tonumber(info.Handles[i].HandleValue) })
    end
    kernel32.CloseHandle(h)
    return res
end

-- [RESTORED] 列出全系统所有句柄
function M.list_system()
    local ok, priv_err = token.enable_privilege("SeDebugPrivilege")
    -- 即使提权失败也尝试继续，但也记录警告
    
    -- SystemExtendedHandleInformation = 64
    local buf, final_size, ret_len = native.query_system_info(64, 4 * 1024 * 1024)
    if not buf then 
        return nil, tostring(final_size) 
    end
    
    local info = ffi.cast("SYSTEM_HANDLE_INFORMATION_EX*", buf)
    local count = tonumber(info.NumberOfHandles)
    
    local res = table_new(count, 0)
    setmetatable(res, { __index = table_ext })
    
    for i=0, count-1 do
        local h = info.Handles[i]
        res[i+1] = {
            pid = tonumber(h.UniqueProcessId),
            val = tonumber(h.HandleValue),
            access = tonumber(h.GrantedAccess),
            -- [FIX] Cast pointer to number (uintptr_t)
            obj = tonumber(ffi.cast("uintptr_t", h.Object))
        }
    end
    return res
end

function M.find_lockers(path)
    local target = native.dos_path_to_nt_path(path):lower()
    local pids = {}
    
    local sys_handles, err = M.list_system()
    if not sys_handles then 
        return {} 
    end
    
    local cur = kernel32.GetCurrentProcess()
    local name_buf = ffi.new("uint8_t[4096]")
    
    for _, h in ipairs(sys_handles) do
        if h.pid ~= kernel32.GetCurrentProcessId() then
            local hProc = kernel32.OpenProcess(0x40, false, h.pid) -- DUP_HANDLE
            if hProc then
                local dup = ffi.new("HANDLE[1]")
                if ntdll.NtDuplicateObject(hProc, ffi.cast("HANDLE", h.val), cur, dup, 0, 0, 0) == 0 then
                    if kernel32.GetFileType(dup[0]) == 1 then -- File
                        if ntdll.NtQueryObject(dup[0], 1, name_buf, 4096, nil) == 0 then
                            local ni = ffi.cast("OBJECT_NAME_INFORMATION*", name_buf)
                            if ni.Name.Buffer ~= nil then
                                local n = util.from_wide(ni.Name.Buffer, ni.Name.Length/2)
                                if n and n:lower():find(target, 1, true) then
                                    local found = false
                                    for _, exist_pid in ipairs(pids) do if exist_pid == h.pid then found=true; break end end
                                    if not found then table.insert(pids, h.pid) end
                                end
                            end
                        end
                    end
                    kernel32.CloseHandle(dup[0])
                end
                kernel32.CloseHandle(hProc)
            end
        end
    end
    return pids
end

function M.close_remote(pid, val)
    local h = kernel32.OpenProcess(0x40, false, pid)
    if not h then return false end
    local dup = ffi.new("HANDLE[1]")
    local r = ntdll.NtDuplicateObject(h, ffi.cast("HANDLE", val), kernel32.GetCurrentProcess(), dup, 0, 0, 1) -- DUPLICATE_CLOSE_SOURCE
    if r == 0 then kernel32.CloseHandle(dup[0]) end
    kernel32.CloseHandle(h)
    return r == 0
end

return M