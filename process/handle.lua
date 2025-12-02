local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local C = ffi.C

local function resolve_nt_path(dos_path)
    local buf = ffi.new("wchar_t[1024]")
    local clean_path = dos_path:gsub("\\$", "")
    local res = kernel32.QueryDosDeviceW(util.to_wide(clean_path), buf, 1024)
    if res == 0 then return nil end
    return util.from_wide(buf)
end

-- [高性能] 获取指定 PID 的句柄快照 (Windows 8+)
function M.list_process_handles(pid)
    local hProcess = kernel32.OpenProcess(C.PROCESS_QUERY_INFORMATION, false, pid)
    if hProcess == nil or hProcess == ffi.cast("HANDLE", -1) then 
        return nil, "OpenProcess failed" 
    end
    
    local buf_size = 0x8000
    local buf = ffi.new("uint8_t[?]", buf_size)
    local ret_len = ffi.new("ULONG[1]")
    
    -- 循环调整缓冲区大小
    while true do
        local status = ntdll.NtQueryInformationProcess(hProcess, C.ProcessHandleInformation, buf, buf_size, ret_len)
        
        if status == C.STATUS_INFO_LENGTH_MISMATCH then
            buf_size = ret_len[0]
            if buf_size == 0 then buf_size = buf_size * 2 end
            buf = ffi.new("uint8_t[?]", buf_size)
        elseif status < 0 then
            kernel32.CloseHandle(hProcess)
            return nil, string.format("NtQueryInformationProcess failed: 0x%X", status)
        else
            break
        end
    end
    
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
    
    kernel32.CloseHandle(hProcess)
    return handles
end

-- [低性能] 全局系统句柄扫描 (兼容旧系统或跨进程搜索)
function M.list_system_handles()
    local buf_size = 0x10000
    local buf = ffi.new("uint8_t[?]", buf_size)
    local ret_len = ffi.new("ULONG[1]")
    
    while true do
        local status = ntdll.NtQuerySystemInformation(C.SystemExtendedHandleInformation, buf, buf_size, ret_len)
        
        if status == C.STATUS_INFO_LENGTH_MISMATCH then
            buf_size = buf_size * 2
            -- 安全限制：避免 OOM
            if buf_size > 64 * 1024 * 1024 then return nil, "Buffer too large" end
            buf = ffi.new("uint8_t[?]", buf_size)
        elseif status < 0 then
            return nil, string.format("NtQuerySystemInformation failed: 0x%X", status)
        else
            break
        end
    end
    
    local handle_info = ffi.cast("SYSTEM_HANDLE_INFORMATION_EX*", buf)
    local handles = {}
    
    for i = 0, tonumber(handle_info.NumberOfHandles) - 1 do
        local h = handle_info.Handles[i]
        table.insert(handles, {
            pid = tonumber(h.UniqueProcessId),
            handle_val = tonumber(h.HandleValue),
            access = tonumber(h.GrantedAccess),
            obj = h.Object
        })
    end
    
    return handles
end

-- 查找锁定文件的进程
-- 注意：因为需要搜索全系统句柄，这里必须用 list_system_handles
function M.find_locking_pids(device_path)
    local target_nt_path = resolve_nt_path(device_path)
    if not target_nt_path then return {}, "Could not resolve NT path" end
    target_nt_path = target_nt_path:lower()
    
    local handles = M.list_system_handles()
    if not handles then return {}, "Failed to list handles" end
    
    local current_pid = kernel32.GetCurrentProcessId()
    local locking_pids = {}
    local seen_pids = {}
    
    local name_buf_size = 4096
    local name_buf = ffi.new("uint8_t[?]", name_buf_size)
    
    for _, h in ipairs(handles) do
        if h.pid ~= current_pid then
            local hProc = kernel32.OpenProcess(
                bit.bor(C.PROCESS_DUP_HANDLE, C.PROCESS_QUERY_INFORMATION), 
                false, h.pid
            )
            
            if hProc ~= ffi.cast("HANDLE", -1) and hProc ~= nil then
                local dup_handle = ffi.new("HANDLE[1]")
                
                local status = ntdll.NtDuplicateObject(
                    hProc, ffi.cast("HANDLE", h.handle_val),
                    kernel32.GetCurrentProcess(), dup_handle,
                    0, 0, 0 
                )
                
                if status == 0 then
                    -- 优化：先检查类型是否为 File/Disk
                    local fileType = kernel32.GetFileType(dup_handle[0])
                    
                    if fileType == C.FILE_TYPE_DISK then
                        local ret_len = ffi.new("ULONG[1]")
                        status = ntdll.NtQueryObject(
                            dup_handle[0], C.ObjectNameInformation,
                            name_buf, name_buf_size, ret_len
                        )
                        
                        if status == 0 then
                            local name_info = ffi.cast("OBJECT_NAME_INFORMATION*", name_buf)
                            if name_info.Name.Buffer ~= nil and name_info.Name.Length > 0 then
                                local obj_path = util.from_wide(name_info.Name.Buffer, name_info.Name.Length / 2)
                                if obj_path and obj_path:lower():find(target_nt_path, 1, true) then
                                    if not seen_pids[h.pid] then
                                        table.insert(locking_pids, h.pid)
                                        seen_pids[h.pid] = true
                                    end
                                end
                            end
                        end
                    end
                    kernel32.CloseHandle(dup_handle[0])
                end
                kernel32.CloseHandle(hProc)
            end
        end
    end
    
    return locking_pids
end

-- 强制关闭远程句柄 (System Informer 风格)
-- 原理: DuplicateHandle(DUPLICATE_CLOSE_SOURCE) -> Local Close
function M.close_remote_handle(pid, handle_val)
    local hProc = kernel32.OpenProcess(C.PROCESS_DUP_HANDLE, false, pid)
    if not hProc then return false, "OpenProcess failed" end
    
    local dup_handle = ffi.new("HANDLE[1]")
    -- DUPLICATE_CLOSE_SOURCE = 0x1
    local status = ntdll.NtDuplicateObject(
        hProc, 
        ffi.cast("HANDLE", handle_val), 
        kernel32.GetCurrentProcess(), 
        dup_handle, 
        0, 0, 1
    )
    
    kernel32.CloseHandle(hProc)
    
    if status < 0 then return false, string.format("NtDuplicateObject failed: 0x%X", status) end
    
    -- 关闭我们要过来的句柄，彻底销毁它
    kernel32.CloseHandle(dup_handle[0])
    return true
end

return M