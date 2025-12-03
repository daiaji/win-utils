local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- PH_LARGE_BUFFER_SIZE (256 MB safety limit)
local MAX_BUFFER_SIZE = 256 * 1024 * 1024 

-- [Native Helper]
-- Initialize UNICODE_STRING from Lua String
-- Returns: cdata<UNICODE_STRING>, anchor (buffer)
function M.to_unicode_string(str)
    if not str then return nil, nil end
    local wstr = util.to_wide(str)
    -- Calculate byte length (excluding null terminator for Length)
    local len_bytes = (#str) * 2 
    -- Re-calculate accurately based on utf-16 conversion if needed, 
    -- but util.to_wide already handles conversion.
    -- Better way: scan wstr length.
    local scan_len = 0
    while wstr[scan_len] ~= 0 do scan_len = scan_len + 1 end
    
    local us = ffi.new("UNICODE_STRING")
    us.Buffer = wstr
    us.Length = scan_len * 2
    us.MaximumLength = (scan_len + 1) * 2
    
    return us, wstr -- Return wstr as anchor
end

-- [Native Helper]
-- Initialize OBJECT_ATTRIBUTES
-- Returns: cdata<OBJECT_ATTRIBUTES>, anchor_table (keeps wstr/us alive)
function M.init_object_attributes(path_str, root_dir, attributes)
    local us, anchor = M.to_unicode_string(path_str)
    
    local oa = ffi.new("OBJECT_ATTRIBUTES")
    oa.Length = ffi.sizeof(oa)
    oa.RootDirectory = root_dir or nil
    oa.ObjectName = us -- pointer assignment
    oa.Attributes = attributes or C.OBJ_CASE_INSENSITIVE
    oa.SecurityDescriptor = nil
    oa.SecurityQualityOfService = nil
    
    -- Keep alive list
    local anchors = { us, anchor }
    return oa, anchors
end

-- [Native Helper]
-- Convert DOS path (C:\Windows) to NT path (\??\C:\Windows)
function M.dos_path_to_nt_path(dos_path)
    if not dos_path then return nil end
    if dos_path:sub(1, 4) == "\\??\\" then return dos_path end
    if dos_path:sub(1, 1) == "\\" then return dos_path end -- Already relative or NT?
    
    return "\\??\\" .. dos_path
end

-- 通用 helper：处理 NtQuerySystemInformation 的变长 Buffer 逻辑
-- 参考 phlib: PhEnumProcesses / PhEnumHandles
function M.query_system_info(info_class, initial_size)
    local size = initial_size or 0x4000
    local buf = ffi.new("uint8_t[?]", size)
    local ret_len = ffi.new("ULONG[1]")
    
    while true do
        local status = ntdll.NtQuerySystemInformation(info_class, buf, size, ret_len)
        
        if status == C.STATUS_INFO_LENGTH_MISMATCH then
            size = ret_len[0]
            if size == 0 then size = size * 2 end -- Fallback if ret_len not set
            
            if size > MAX_BUFFER_SIZE then return nil, "Buffer too large" end
            
            buf = ffi.new("uint8_t[?]", size)
        elseif status < 0 then
            return nil, string.format("NtQuerySystemInformation failed: 0x%X", status)
        else
            return buf, size, ret_len[0]
        end
    end
end

-- 将 UNICODE_STRING 转为 Lua String
function M.u_str(us)
    if us.Buffer == nil or us.Length == 0 then return "" end
    return util.from_wide(us.Buffer, us.Length / 2)
end

return M