local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.core.util'

local M = {}

local FO_DELETE = 0x0003
local FOF_SILENT = 0x0004
local FOF_NOCONFIRMATION = 0x0010
local FOF_ALLOWUNDO = 0x0040
local FOF_NOERRORUI = 0x0400

local SHERB_NOCONFIRMATION = 0x00000001
local SHERB_NOPROGRESSUI = 0x00000002
local SHERB_NOSOUND = 0x00000004

local function shell32()
    local ok, mod = pcall(function() return require 'ffi.req' 'Windows.sdk.shell32' end)
    if not ok then return nil, mod end
    return mod
end

local function multi_sz(paths)
    local joined = table.concat(paths, "\0") .. "\0\0"
    return util.to_wide(joined)
end

local function normalize_paths(path_or_paths)
    if type(path_or_paths) == "string" then return { path_or_paths } end
    if type(path_or_paths) == "table" then return path_or_paths end
    return nil, "path or paths table required"
end

function M.delete(path_or_paths, opts)
    opts = opts or {}
    local paths, err = normalize_paths(path_or_paths)
    if not paths then return nil, err end
    if #paths == 0 then return true end

    if opts.dry_run then
        return { ok = true, dry_run = true, paths = paths }
    end

    local sh, load_err = shell32()
    if not sh then return nil, "shell32 unavailable: " .. tostring(load_err) end

    local op = ffi.new("SHFILEOPSTRUCTW")
    op.wFunc = FO_DELETE
    op.pFrom = multi_sz(paths)
    op.fFlags = bit.bor(FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI)
    if opts.silent ~= false then op.fFlags = bit.bor(op.fFlags, FOF_SILENT) end

    local rc = sh.SHFileOperationW(op)
    if rc ~= 0 then return nil, string.format("SHFileOperationW failed: %d", tonumber(rc)) end
    if op.fAnyOperationsAborted ~= 0 then return nil, "operation aborted" end
    return true
end

function M.empty(root, opts)
    opts = opts or {}
    if opts.dry_run then
        return { ok = true, dry_run = true, root = root }
    end

    local sh, load_err = shell32()
    if not sh then return nil, "shell32 unavailable: " .. tostring(load_err) end

    local flags = bit.bor(SHERB_NOCONFIRMATION, SHERB_NOPROGRESSUI, SHERB_NOSOUND)
    local hr = sh.SHEmptyRecycleBinW(nil, root and util.to_wide(root) or nil, flags)
    if hr < 0 then return nil, string.format("SHEmptyRecycleBinW failed: 0x%X", tonumber(hr)) end
    return true
end

function M.info(root)
    local sh, load_err = shell32()
    if not sh then return nil, "shell32 unavailable: " .. tostring(load_err) end

    local info = ffi.new("SHQUERYRBINFO")
    info.cbSize = ffi.sizeof(info)
    local hr = sh.SHQueryRecycleBinW(root and util.to_wide(root) or nil, info)
    if hr < 0 then return nil, string.format("SHQueryRecycleBinW failed: 0x%X", tonumber(hr)) end
    return { size = tonumber(info.i64Size), items = tonumber(info.i64NumItems) }
end

return M
