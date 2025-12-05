local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.core.util'

local M = {}

function M.parse_cmdline(cmd_line)
    if not cmd_line or cmd_line == "" then return {} end
    local num = ffi.new("int[1]")
    local args_w = shell32.CommandLineToArgvW(util.to_wide(cmd_line), num)
    if args_w == nil then return {} end
    local res = {}
    for i = 0, num[0] - 1 do table.insert(res, util.from_wide(args_w[i])) end
    kernel32.LocalFree(args_w)
    return res
end

function M.get_args()
    local cmd = kernel32.GetCommandLineW()
    if cmd == nil then return {} end
    local num = ffi.new("int[1]")
    local args_w = shell32.CommandLineToArgvW(cmd, num)
    if args_w == nil then return {} end
    local res = {}
    for i = 0, num[0] - 1 do table.insert(res, util.from_wide(args_w[i])) end
    kernel32.LocalFree(args_w)
    return res
end

-- [Restored] Alias for backward compatibility
M.get_arguments = M.get_args

function M.browse(title)
    local bi = ffi.new("BROWSEINFOW")
    bi.ulFlags = 0x41 
    if title then bi.lpszTitle = util.to_wide(title) end
    local pidl = shell32.SHBrowseForFolderW(bi)
    if pidl == nil then return nil end
    local path = ffi.new("wchar_t[260]")
    local res = nil
    if shell32.SHGetPathFromIDListW(pidl, path) ~= 0 then
        res = util.from_wide(path)
    end
    ole32.CoTaskMemFree(pidl)
    return res
end

return M