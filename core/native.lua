local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local C = require 'win-utils.core.ffi_defs'

local M = {}

function M.open_internal(path, access, share, creation, flags)
    local wpath = util.to_wide(path)
    if not wpath then return nil, "Invalid path" end
    local h = kernel32.CreateFileW(wpath, access, share, nil, creation, flags, nil)
    if h == ffi.cast("HANDLE", -1) then return nil, util.last_error() end
    return Handle(h)
end

function M.open_file(path, mode, share_mode)
    local access = C.GENERIC_READ
    if mode and mode:find("w") then access = bit.bor(access, C.GENERIC_WRITE) end
    if mode and mode:find("d") then access = bit.bor(access, C.DELETE) end
    
    local share
    if type(share_mode) == "number" then
        share = share_mode
    elseif share_mode == "exclusive" then
        share = 0
    elseif share_mode == true then 
        -- [FIX] "true" means "shared", i.e., permissive sharing
        -- Allow others to Read/Write/Delete. Essential for opening C: drive.
        share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    elseif share_mode == "read" then 
        share = C.FILE_SHARE_READ 
    else
        -- Default: Permissive sharing
        share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    end
    
    local flags = bit.bor(C.FILE_ATTRIBUTE_NORMAL, C.FILE_FLAG_BACKUP_SEMANTICS)
    return M.open_internal(path, access, share, C.OPEN_EXISTING, flags)
end

function M.open_device(path, mode, share_mode)
    local p = path
    if type(p)=="number" then p="\\\\.\\PhysicalDrive"..p
    elseif type(p)=="string" and p:match("^%a:$") then p="\\\\.\\"..p end
    
    local access = C.GENERIC_READ
    if mode and mode:find("w") then access = bit.bor(access, C.GENERIC_WRITE) end
    
    local share
    if type(share_mode) == "number" then
        share = share_mode
    elseif share_mode == "exclusive" then
        share = 0
    elseif share_mode == "read" or share_mode == true then
        share = C.FILE_SHARE_READ 
    else
        share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE)
    end
    
    return M.open_internal(p, access, share, C.OPEN_EXISTING, bit.bor(C.FILE_FLAG_NO_BUFFERING, C.FILE_FLAG_WRITE_THROUGH))
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
    oa.Length = ffi.sizeof(oa); oa.RootDirectory = root_dir or nil
    oa.ObjectName = us; oa.Attributes = attributes or 0x40 -- OBJ_CASE_INSENSITIVE
    return oa, { us, anchor }
end

function M.dos_path_to_nt_path(dos_path)
    if not dos_path then return nil end
    -- [FIX] Ensure proper prefix handling
    if dos_path:sub(1, 4) == "\\??\\" then return dos_path end
    return "\\??\\" .. dos_path
end

function M.query_variable_size(func, first_arg, info_class, initial_size)
    local size = initial_size or 4096
    local buf = ffi.new("uint8_t[?]", size)
    local ret_len = ffi.new("ULONG[1]")
    while true do
        local status
        if info_class then status = func(first_arg, info_class, buf, size, ret_len)
        else status = func(first_arg, buf, size, ret_len) end
        if status == 0xC0000004 or status == 0x80000005 or status == 0xC0000023 then
            size = (ret_len[0] == 0) and size * 2 or ret_len[0]
            if size > 64*1024*1024 then return nil, "Buffer overflow" end
            buf = ffi.new("uint8_t[?]", size)
        elseif status < 0 then return nil, status else return buf, size, ret_len[0] end
    end
end

return M