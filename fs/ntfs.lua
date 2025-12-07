local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'
local Handle = require 'win-utils.core.handle'

ffi.cdef[[
    typedef struct _REPARSE_DATA_BUFFER_HEADER {
        ULONG  ReparseTag;
        USHORT ReparseDataLength;
        USHORT Reserved;
    } REPARSE_DATA_BUFFER_HEADER;

    typedef struct _SYMBOLIC_LINK_REPARSE_BUFFER {
        ULONG  ReparseTag;
        USHORT ReparseDataLength;
        USHORT Reserved;
        USHORT SubstituteNameOffset;
        USHORT SubstituteNameLength;
        USHORT PrintNameOffset;
        USHORT PrintNameLength;
        ULONG  Flags;
        WCHAR  PathBuffer[1];
    } SYMBOLIC_LINK_REPARSE_BUFFER;

    typedef struct _MOUNT_POINT_REPARSE_BUFFER {
        ULONG  ReparseTag;
        USHORT ReparseDataLength;
        USHORT Reserved;
        USHORT SubstituteNameOffset;
        USHORT SubstituteNameLength;
        USHORT PrintNameOffset;
        USHORT PrintNameLength;
        WCHAR  PathBuffer[1];
    } MOUNT_POINT_REPARSE_BUFFER;
]]

local M = {}

-- Helper to create Reparse Buffer for Junctions
local function create_reparse_buf(target, print_name)
    local sub = target
    if not sub:match("^%\\%?%?\\") then
        if sub:match("^%a:") then sub = "\\??\\" .. sub end
    end
    
    local wsub = util.to_wide(sub)
    local wprint = util.to_wide(print_name or target)
    
    local sub_len = 0; while wsub[sub_len]~=0 do sub_len=sub_len+1 end; sub_len=sub_len*2
    local print_len = 0; while wprint[print_len]~=0 do print_len=print_len+1 end; print_len=print_len*2
    
    local total = 16 + sub_len + print_len + 4 
    local buf = ffi.new("uint8_t[?]", total)
    local view = ffi.cast("uint32_t*", buf)
    
    view[0] = 0xA0000003 -- IO_REPARSE_TAG_MOUNT_POINT
    local u16 = ffi.cast("uint16_t*", buf)
    u16[2] = sub_len + print_len + 12 
    u16[3] = 0 
    
    u16[4] = 0 
    u16[5] = sub_len 
    u16[6] = sub_len + 2 
    u16[7] = print_len 
    
    ffi.copy(buf + 16, wsub, sub_len)
    ffi.copy(buf + 16 + sub_len + 2, wprint, print_len)
    
    return buf, total
end

function M.mklink(link, target, type)
    if type == "junction" then
        if kernel32.CreateDirectoryW(util.to_wide(link), nil) == 0 then 
            return false, util.last_error("CreateDirectory failed") 
        end
        
        -- GENERIC_WRITE, OPEN_EXISTING, BACKUP|REPARSE
        local hDir = kernel32.CreateFileW(util.to_wide(link), 0x40000000, 0, nil, 3, 0x02200000, nil) 
        if hDir == ffi.cast("HANDLE", -1) then 
            kernel32.RemoveDirectoryW(util.to_wide(link))
            return false, util.last_error("CreateFile failed") 
        end
        
        local buf, sz = create_reparse_buf(target)
        local bytes = ffi.new("DWORD[1]")
        local res = kernel32.DeviceIoControl(hDir, 0x900A4, buf, sz, nil, 0, bytes, nil) -- FSCTL_SET_REPARSE_POINT
        kernel32.CloseHandle(hDir)
        
        if res == 0 then 
            kernel32.RemoveDirectoryW(util.to_wide(link))
            return false, util.last_error("DeviceIoControl failed") 
        end
        return true
    end

    local wl, wt = util.to_wide(link), util.to_wide(target)
    if type == "hard" then 
        if kernel32.CreateHardLinkW(wl, wt, nil) == 0 then
            return false, util.last_error("CreateHardLink failed")
        end
    else
        if kernel32.CreateSymbolicLinkW(wl, wt, type == "dir" and 1 or 0) == 0 then
            return false, util.last_error("CreateSymbolicLink failed")
        end
    end
    return true
end

function M.read_link(path)
    -- OPEN_REPARSE_POINT (0x00200000) | FILE_FLAG_BACKUP_SEMANTICS (0x02000000)
    local flags = 0x02200000 
    local access = 0x80000000 -- GENERIC_READ
    
    local h = native.open_internal(path, access, 1, 3, flags) -- ShareRead, OpenExisting
    if not h then return nil, "Open failed" end
    
    -- [FIX] Allocate explicit buffer for IOCTL output
    local out_size = 16384
    local out_buf = ffi.new("uint8_t[?]", out_size)
    local buf, err = util.ioctl(h:get(), 0x900A8, nil, 0, out_buf, out_size) -- FSCTL_GET_REPARSE_POINT
    h:close()
    
    if not buf then return nil, err end
    
    local hdr = ffi.cast("REPARSE_DATA_BUFFER_HEADER*", buf)
    
    if hdr.ReparseTag == 0xA000000C then -- SYMLINK
        local sl = ffi.cast("SYMBOLIC_LINK_REPARSE_BUFFER*", buf)
        return util.from_wide(sl.PathBuffer + sl.SubstituteNameOffset/2, sl.SubstituteNameLength/2), "Symlink"
    elseif hdr.ReparseTag == 0xA0000003 then -- MOUNT
        local mp = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
        return util.from_wide(mp.PathBuffer + mp.SubstituteNameOffset/2, mp.SubstituteNameLength/2), "Junction"
    end
    return nil, string.format("Unknown Tag: 0x%X", hdr.ReparseTag)
end

function M.unlink(path)
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    if a == 0xFFFFFFFF or bit.band(a, 0x400) == 0 then return false, "Not a link" end
    if bit.band(a, 0x10) ~= 0 then 
        if kernel32.RemoveDirectoryW(util.to_wide(path)) == 0 then return false, util.last_error() end
    else 
        if kernel32.DeleteFileW(util.to_wide(path)) == 0 then return false, util.last_error() end
    end
    return true
end

function M.list_streams(path)
    local h = ffi.new("HANDLE[1]")
    local d = ffi.new("WIN32_FIND_STREAM_DATA")
    h[0] = kernel32.FindFirstStreamW(util.to_wide(path), 0, d, 0)
    if h[0] == ffi.cast("HANDLE", -1) then return {} end
    local t = {}
    repeat table.insert(t, {name=util.from_wide(d.cStreamName), size=tonumber(d.StreamSize.QuadPart)})
    until kernel32.FindNextStreamW(h[0], d) == 0
    kernel32.FindClose(h[0])
    return t
end

function M.set_compression(path, enable)
    local h = native.open_file(path, "rw")
    if not h then return false, "Open failed" end
    local st = ffi.new("uint16_t[1]", enable and 1 or 0)
    local r, err = util.ioctl(h:get(), 0x9C040, st, 2) -- FSCTL_SET_COMPRESSION
    h:close()
    return r ~= nil, err
end

function M.set_sparse(path, enable)
    local h = native.open_file(path, "rw")
    if not h then return false, "Open failed" end
    local r, err = util.ioctl(h:get(), 0x900C4) -- FSCTL_SET_SPARSE
    h:close()
    return r ~= nil, err
end

return M