local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- PH_LARGE_BUFFER_SIZE (256 MB safety limit)
local MAX_BUFFER_SIZE = 256 * 1024 * 1024 

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