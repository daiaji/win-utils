local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local C = ffi.C

local function open_internal(path, access, share, creation, flags)
    local wpath = util.to_wide(path)
    if not wpath then return nil, "Invalid path" end
    
    local h = kernel32.CreateFileW(wpath, access, share, nil, creation, flags, nil)
    
    if h == ffi.cast("HANDLE", -1) then
        return nil, util.format_error()
    end
    
    return Handle(h)
end

function M.open_file(path, write, exclusive)
    local access = write and bit.bor(C.GENERIC_READ, C.GENERIC_WRITE) or C.GENERIC_READ
    local share = exclusive and 0 or bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    local flags = bit.bor(C.FILE_ATTRIBUTE_NORMAL, C.FILE_FLAG_BACKUP_SEMANTICS)
    
    return open_internal(path, access, share, C.OPEN_EXISTING, flags)
end

function M.open_device(path, write, exclusive)
    local p = path
    if type(p) == "string" then
        if p:match("^%a:$") then p = "\\\\.\\" .. p
        elseif p:match("^%a:\\$") then p = "\\\\.\\" .. p:sub(1,2) 
        end
    elseif type(p) == "number" then 
        p = "\\\\.\\PhysicalDrive" .. p
    end
    
    local access = write and bit.bor(C.GENERIC_READ, C.GENERIC_WRITE) or C.GENERIC_READ
    local share = exclusive and C.FILE_SHARE_READ or bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    local flags = bit.bor(C.FILE_FLAG_NO_BUFFERING, C.FILE_FLAG_WRITE_THROUGH)
    
    return open_internal(p, access, share, C.OPEN_EXISTING, flags)
end

function M.to_unicode_string(str)
    if not str then return nil, nil end
    local wstr = util.to_wide(str)
    local len = 0; while wstr[len] ~= 0 do len = len + 1 end
    local us = ffi.new("UNICODE_STRING")
    us.Buffer = wstr; us.Length = len * 2; us.MaximumLength = (len + 1) * 2
    return us, wstr 
end

function M.init_object_attributes(path_str, root_dir, attributes)
    local us, anchor = M.to_unicode_string(path_str)
    local oa = ffi.new("OBJECT_ATTRIBUTES")
    oa.Length = ffi.sizeof(oa)
    oa.RootDirectory = root_dir or nil
    oa.ObjectName = us
    oa.Attributes = attributes or C.OBJ_CASE_INSENSITIVE
    return oa, { us, anchor }
end

function M.dos_path_to_nt_path(dos_path)
    if not dos_path then return nil end
    if dos_path:sub(1, 4) == "\\??\\" or dos_path:sub(1, 1) == "\\" then return dos_path end
    return "\\??\\" .. dos_path
end

local MAX_BUFFER_SIZE = 64 * 1024 * 1024 

function M.query_variable_size(func, first_arg, info_class, initial_size)
    local size = initial_size or 0x4000
    local buf = ffi.new("uint8_t[?]", size)
    local ret_len = ffi.new("ULONG[1]")
    while true do
        local status
        if first_arg and info_class then status = func(first_arg, info_class, buf, size, ret_len)
        else status = func(first_arg, buf, size, ret_len) end
        
        if status == C.STATUS_INFO_LENGTH_MISMATCH or status == C.STATUS_BUFFER_OVERFLOW or status == C.STATUS_BUFFER_TOO_SMALL then
            size = ret_len[0] == 0 and size * 2 or ret_len[0]
            if size > MAX_BUFFER_SIZE then return nil, "Buffer too large" end
            buf = ffi.new("uint8_t[?]", size)
        elseif status < 0 then
            return nil, string.format("Native Query failed: 0x%X", status)
        else
            return buf, size, ret_len[0]
        end
    end
end

return M