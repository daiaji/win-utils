local ffi = require 'ffi'
local bit = require 'bit'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local version = require 'ffi.req' 'Windows.sdk.version'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

-- Helper for SHFileOperation
local function sh_op(func, src, dest, flags)
    local sh = ffi.new("SHFILEOPSTRUCTW")
    sh.wFunc = func

    -- [NOTE] SHFileOperation requires the path string to be Double-Null Terminated.
    -- `util.to_wide(src .. "\0")` creates a wide string of `src` + `\0` + (implicit ffi.new `\0`)
    -- Resulting in the required `path \0 \0` format safely.
    sh.pFrom = util.to_wide(src .. "\0")

    if dest then sh.pTo = util.to_wide(dest .. "\0") end

    -- Default Flags: No Confirm, No UI, Silent
    local default_flags = bit.bor(C.FOF_NOCONFIRMATION, C.FOF_NOERRORUI, C.FOF_SILENT)
    sh.fFlags = flags or default_flags

    return shell32.SHFileOperationW(sh) == 0
end

function M.copy(s, d) return sh_op(C.FO_COPY, s, d) end

function M.move(s, d) return sh_op(C.FO_MOVE, s, d) end

function M.delete(p) return sh_op(C.FO_DELETE, p) end

-- 放入回收站 (关键功能)
function M.recycle(p)
    return sh_op(C.FO_DELETE, p, nil, bit.bor(C.FOF_ALLOWUNDO, C.FOF_NOCONFIRMATION, C.FOF_NOERRORUI, C.FOF_SILENT))
end

-- 获取 EXE/DLL 版本信息
function M.get_version(path)
    local wpath = util.to_wide(path)
    local dummy = ffi.new("DWORD[1]")
    local size = version.GetFileVersionInfoSizeW(wpath, dummy)
    if size == 0 then return nil end

    local buf = ffi.new("uint8_t[?]", size)
    if version.GetFileVersionInfoW(wpath, 0, size, buf) == 0 then return nil end

    local verInfo = ffi.new("VS_FIXEDFILEINFO*[1]")
    local verLen = ffi.new("UINT[1]")
    -- Query root block for fixed info
    if version.VerQueryValueW(buf, util.to_wide("\\"), ffi.cast("void**", verInfo), verLen) == 0 then return nil end

    local vi = verInfo[0]
    return string.format("%d.%d.%d.%d",
        bit.rshift(vi.dwFileVersionMS, 16), bit.band(vi.dwFileVersionMS, 0xFFFF),
        bit.rshift(vi.dwFileVersionLS, 16), bit.band(vi.dwFileVersionLS, 0xFFFF))
end

return M
