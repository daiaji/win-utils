local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}

function M.browse_folder(title)
    local bi = ffi.new("BROWSEINFOW")
    bi.ulFlags = 0x41 -- NEWDIALOGSTYLE | RETURNONLYFSDIRS
    if title then bi.lpszTitle = util.to_wide(title) end
    
    local pidl = shell32.SHBrowseForFolderW(bi)
    if pidl == nil then return nil end
    
    local path = ffi.new("wchar_t[260]")
    local res = nil
    if shell32.SHGetPathFromIDListW(pidl, path) ~= 0 then res = util.from_wide(path) end
    shell32.CoTaskMemFree(pidl)
    return res
end

function M.commandline_to_argv(cmd)
    if not cmd then return {} end
    local n = ffi.new("int[1]")
    local arr = shell32.CommandLineToArgvW(util.to_wide(cmd), n)
    if arr == nil then return {} end
    local t = {}
    for i = 0, n[0]-1 do table.insert(t, util.from_wide(arr[i])) end
    kernel32.LocalFree(arr)
    return t
end

function M.get_arguments()
    local cmd = kernel32.GetCommandLineW()
    local n = ffi.new("int[1]")
    local arr = shell32.CommandLineToArgvW(cmd, n)
    if arr == nil then return {} end
    local t = {}
    for i = 0, n[0]-1 do table.insert(t, util.from_wide(arr[i])) end
    kernel32.LocalFree(arr)
    return t
end

return M