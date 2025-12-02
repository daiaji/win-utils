local ffi = require 'ffi'
local bit = require 'bit'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local version = require 'ffi.req' 'Windows.sdk.version'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- [NEW] 自动加载子模块
M.ntfs = require 'win-utils.fs.ntfs'

-- Helper for SHFileOperation
local function sh_op(func, src, dest, flags)
    local sh = ffi.new("SHFILEOPSTRUCTW")
    sh.wFunc = func

    -- SHFileOperation 要求的路径必须以双 NULL 结尾
    local src_w = util.to_wide(src .. "\0")
    sh.pFrom = src_w

    local dest_w = nil
    if dest then 
        dest_w = util.to_wide(dest .. "\0") 
        sh.pTo = dest_w
    end

    -- 默认标志：无确认、无错误UI、静默
    local default_flags = bit.bor(C.FOF_NOCONFIRMATION, C.FOF_NOERRORUI, C.FOF_SILENT)
    sh.fFlags = flags or default_flags

    return shell32.SHFileOperationW(sh) == 0
end

function M.copy(s, d) return sh_op(C.FO_COPY, s, d) end

function M.move(s, d) return sh_op(C.FO_MOVE, s, d) end

function M.delete(p) return sh_op(C.FO_DELETE, p) end

function M.recycle(p)
    return sh_op(C.FO_DELETE, p, nil, bit.bor(C.FOF_ALLOWUNDO, C.FOF_NOCONFIRMATION, C.FOF_NOERRORUI, C.FOF_SILENT))
end

function M.get_version(path)
    local wpath = util.to_wide(path)
    local dummy = ffi.new("DWORD[1]")
    local size = version.GetFileVersionInfoSizeW(wpath, dummy)
    if size == 0 then return nil end

    local buf = ffi.new("uint8_t[?]", size)
    if version.GetFileVersionInfoW(wpath, 0, size, buf) == 0 then return nil end

    local verInfo = ffi.new("VS_FIXEDFILEINFO*[1]")
    local verLen = ffi.new("UINT[1]")
    
    local root_block = util.to_wide("\\")
    
    if version.VerQueryValueW(buf, root_block, ffi.cast("void**", verInfo), verLen) == 0 then return nil end

    local vi = verInfo[0]
    return string.format("%d.%d.%d.%d",
        bit.rshift(vi.dwFileVersionMS, 16), bit.band(vi.dwFileVersionMS, 0xFFFF),
        bit.rshift(vi.dwFileVersionLS, 16), bit.band(vi.dwFileVersionLS, 0xFFFF))
end

-- [NEW] Path Resolution (Reference phlib)
-- Maps NT paths (\Device\HarddiskVolume1\...) to DOS paths (C:\...)
local dos_map_cache = nil

local function build_dos_map()
    local map = {}
    for i = 65, 90 do
        local drive = string.char(i) .. ":"
        local buf = ffi.new("wchar_t[512]")
        if kernel32.QueryDosDeviceW(util.to_wide(drive), buf, 512) > 0 then
            local nt_path = util.from_wide(buf)
            if nt_path then
                map[nt_path] = drive
            end
        end
    end
    return map
end

function M.nt_path_to_dos(nt_path)
    if not nt_path then return nil end
    if not dos_map_cache then dos_map_cache = build_dos_map() end
    
    for device, drive in pairs(dos_map_cache) do
        if nt_path:find(device, 1, true) == 1 then
            return drive .. nt_path:sub(#device + 1)
        end
    end
    return nt_path
end

return M