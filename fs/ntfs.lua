local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'

local M = {}

function M.mklink(link, target, type)
    local wl, wt = util.to_wide(link), util.to_wide(target)
    if type == "hard" then return kernel32.CreateHardLinkW(wl, wt, nil) ~= 0 end
    return kernel32.CreateSymbolicLinkW(wl, wt, type == "dir" and 1 or 0) ~= 0
end

function M.read_link(path)
    local h = native.open_file(path, "r")
    if not h then return nil end
    local buf = util.ioctl(h:get(), 0x900A8, nil, 0, nil, 16384) -- FSCTL_GET_REPARSE_POINT
    h:close()
    if not buf then return nil end
    local hdr = ffi.cast("REPARSE_DATA_BUFFER*", buf)
    if hdr.ReparseTag == 0xA000000C then -- SYMLINK
        local sl = ffi.cast("SYMBOLIC_LINK_REPARSE_BUFFER*", buf)
        return util.from_wide(sl.PathBuffer + sl.SubstituteNameOffset/2, sl.SubstituteNameLength/2), "Symlink"
    elseif hdr.ReparseTag == 0xA0000003 then -- MOUNT
        local mp = ffi.cast("MOUNT_POINT_REPARSE_BUFFER*", buf)
        return util.from_wide(mp.PathBuffer + mp.SubstituteNameOffset/2, mp.SubstituteNameLength/2), "Junction"
    end
    return nil, "Unknown"
end

function M.unlink(path)
    local a = kernel32.GetFileAttributesW(util.to_wide(path))
    if a == 0xFFFFFFFF or bit.band(a, 0x400) == 0 then return false, "Not a link" end
    if bit.band(a, 0x10) ~= 0 then return kernel32.RemoveDirectoryW(util.to_wide(path)) ~= 0
    else return kernel32.DeleteFileW(util.to_wide(path)) ~= 0 end
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
    if not h then return false end
    local st = ffi.new("uint16_t[1]", enable and 1 or 0)
    local r = util.ioctl(h:get(), 0x9C040, st, 2) -- FSCTL_SET_COMPRESSION
    h:close()
    return r ~= nil
end

function M.set_sparse(path, enable)
    local h = native.open_file(path, "rw")
    if not h then return false end
    local r = util.ioctl(h:get(), 0x900C4) -- FSCTL_SET_SPARSE
    h:close()
    return r ~= nil
end

return M