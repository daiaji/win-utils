local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}
local C = ffi.C

-- Helper: Convert DOS path (C:\) to NT Path (\Device\HarddiskVolumeX\)
-- Needed because NtQueryObject returns NT paths.
local function resolve_nt_path(dos_path)
    local buf = ffi.new("wchar_t[1024]")
    -- Remove trailing backslash
    local clean_path = dos_path:gsub("\\$", "")
    
    local res = kernel32.QueryDosDeviceW(util.to_wide(clean_path), buf, 1024)
    if res == 0 then return nil end
    
    -- QueryDosDevice returns multiple strings, we just want the first one
    return util.from_wide(buf)
end

-- Port of Rufus `PhEnumHandlesEx` (simplified for Lua)
-- Returns a Lua table of handle info
function M.list_system_handles()
    local buf_size = 0x10000
    local buf = ffi.new("uint8_t[?]", buf_size)
    local ret_len = ffi.new("ULONG[1]")
    
    while true do
        local status = ntdll.NtQuerySystemInformation(C.SystemExtendedHandleInformation, buf, buf_size, ret_len)
        
        if status == C.STATUS_INFO_LENGTH_MISMATCH then
            buf_size = buf_size * 2
            -- Safety limit: 64MB
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
            obj = h.Object -- Pointer
        })
    end
    
    return handles
end

-- Find PIDs that have an open handle to the specified device path
-- device_path: e.g. "\\.\PhysicalDrive1" or "E:"
function M.find_locking_pids(device_path)
    local target_nt_path = resolve_nt_path(device_path)
    if not target_nt_path then return {}, "Could not resolve NT path" end
    
    -- [FIX] Case-insensitive normalization
    target_nt_path = target_nt_path:lower()
    
    local handles = M.list_system_handles()
    if not handles then return {}, "Failed to list handles" end
    
    local current_pid = kernel32.GetCurrentProcessId()
    local locking_pids = {}
    local seen_pids = {}
    
    -- Helper Buffer for Object Name Query
    local name_buf_size = 4096
    local name_buf = ffi.new("uint8_t[?]", name_buf_size)
    
    for _, h in ipairs(handles) do
        -- Skip our own process and irrelevant handles
        if h.pid ~= current_pid then
            
            -- Open Source Process
            local hProc = kernel32.OpenProcess(
                bit.bor(C.PROCESS_DUP_HANDLE, C.PROCESS_QUERY_INFORMATION), 
                false, h.pid
            )
            
            if hProc ~= ffi.cast("HANDLE", -1) and hProc ~= nil then
                local dup_handle = ffi.new("HANDLE[1]")
                
                -- Duplicate handle to our process to query it
                local status = ntdll.NtDuplicateObject(
                    hProc, ffi.cast("HANDLE", h.handle_val),
                    kernel32.GetCurrentProcess(), dup_handle,
                    0, 0, 0 
                )
                
                if status == 0 then -- STATUS_SUCCESS
                    -- [CRITICAL] Must filter for FILE_TYPE_DISK to avoid hanging on pipes
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
                                
                                -- [FIX] Case-insensitive comparison
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

return M