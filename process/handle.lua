local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local native = require 'win-utils.native'

local M = {}
local C = ffi.C

print("[HANDLE] Loading...")

local function resolve_nt_path(dos_path)
    local buf = ffi.new("wchar_t[1024]")
    local clean_path = dos_path:gsub("\\$", "")
    local res = kernel32.QueryDosDeviceW(util.to_wide(clean_path), buf, 1024)
    if res == 0 then return nil end
    return util.from_wide(buf)
end

function M.list_process_handles(pid)
    local hProc = kernel32.OpenProcess(C.PROCESS_QUERY_INFORMATION, false, pid)
    if not hProc or hProc == ffi.cast("HANDLE", -1) then return nil end
    
    local buf, size, _ = native.query_variable_size(
        ntdll.NtQueryInformationProcess, 
        hProc, 
        C.ProcessHandleInformation, 
        0x8000
    )
    
    kernel32.CloseHandle(hProc)
    if not buf then return nil, "Query failed" end
    
    local snapshot = ffi.cast("PROCESS_HANDLE_SNAPSHOT_INFORMATION*", buf)
    local handles = {}
    
    for i = 0, tonumber(snapshot.NumberOfHandles) - 1 do
        local entry = snapshot.Handles[i]
        table.insert(handles, {
            handle_val = tonumber(entry.HandleValue),
            access = tonumber(entry.GrantedAccess),
            attributes = tonumber(entry.HandleAttributes),
            type_index = tonumber(entry.ObjectTypeIndex)
        })
    end
    
    return handles
end

function M.find_locking_pids(device_path)
    local target_nt_path = resolve_nt_path(device_path)
    if not target_nt_path then return {} end
    target_nt_path = target_nt_path:lower()
    
    -- [Lazy Load] win-utils.process (Break circular dep with handle.lua)
    local proc_mod = require 'win-utils.process'
    
    local locking_pids = {}
    local seen_pids = {}
    local name_buf = ffi.new("uint8_t[4096]") 
    local current_pid = kernel32.GetCurrentProcessId()
    
    -- 遍历所有进程
    for p_info in proc_mod.each() do
        if p_info.pid ~= current_pid then
            local handles = M.list_process_handles(p_info.pid)
            if handles then
                local hProc = kernel32.OpenProcess(C.PROCESS_DUP_HANDLE, false, p_info.pid)
                
                if hProc and hProc ~= ffi.cast("HANDLE", -1) then
                    for _, h in ipairs(handles) do
                        local dup_handle = ffi.new("HANDLE[1]")
                        
                        -- DuplicateHandle
                        if ntdll.NtDuplicateObject(hProc, ffi.cast("HANDLE", h.handle_val), kernel32.GetCurrentProcess(), dup_handle, 0, 0, 0) == 0 then
                            
                            -- 检查是否为 Disk/File 类型
                            if kernel32.GetFileType(dup_handle[0]) == C.FILE_TYPE_DISK then
                                 -- 查询对象名称
                                 if ntdll.NtQueryObject(dup_handle[0], C.ObjectNameInformation, name_buf, 4096, nil) == 0 then
                                     local ni = ffi.cast("OBJECT_NAME_INFORMATION*", name_buf)
                                     if ni.Name.Buffer ~= nil and ni.Name.Length > 0 then
                                         local path = util.from_wide(ni.Name.Buffer, ni.Name.Length / 2)
                                         if path and path:lower():find(target_nt_path, 1, true) then
                                             if not seen_pids[p_info.pid] then
                                                 table.insert(locking_pids, p_info.pid)
                                                 seen_pids[p_info.pid] = true
                                             end
                                             kernel32.CloseHandle(dup_handle[0])
                                             -- 找到即跳出当前进程循环
                                             break 
                                         end
                                     end
                                 end
                            end
                            kernel32.CloseHandle(dup_handle[0])
                        end
                        if seen_pids[p_info.pid] then break end
                    end
                    kernel32.CloseHandle(hProc)
                end
            end
        end
    end
    
    return locking_pids
end

function M.close_remote_handle(pid, handle_val)
    local hProc = kernel32.OpenProcess(C.PROCESS_DUP_HANDLE, false, pid)
    if not hProc then return false, "OpenProcess failed" end
    
    local dup_handle = ffi.new("HANDLE[1]")
    -- DUPLICATE_CLOSE_SOURCE = 0x1
    local status = ntdll.NtDuplicateObject(hProc, ffi.cast("HANDLE", handle_val), kernel32.GetCurrentProcess(), dup_handle, 0, 0, 1)
    
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return false, string.format("0x%X", status) end
    
    kernel32.CloseHandle(dup_handle[0])
    return true
end

print("[HANDLE] Loaded.")
return M