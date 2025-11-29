local ffi = require 'ffi'
local bit = require 'bit'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}

function M.browse_folder(prompt)
    local bi = ffi.new("BROWSEINFOW")
    -- BIF_RETURNONLYFSDIRS (1) | BIF_NEWDIALOGSTYLE (0x40)
    bi.ulFlags = bit.bor(0x0001, 0x0040)
    if prompt then bi.lpszTitle = util.to_wide(prompt) end

    local pidl = shell32.SHBrowseForFolderW(bi)
    local result = nil

    if pidl ~= nil then
        local path = ffi.new("wchar_t[260]")
        if shell32.SHGetPathFromIDListW(pidl, path) ~= 0 then
            result = util.from_wide(path)
        end
        shell32.CoTaskMemFree(pidl)
    end

    return result
end

-- 导出 CommandLineToArgvW 封装，保持与原始代码一致的接口
M.commandline_to_argv = function(cmd_line)
    if not cmd_line or cmd_line == "" then return {} end

    local argc_ptr = ffi.new("int[1]")
    local w_cmd_line = util.to_wide(cmd_line)

    local argv_w = shell32.CommandLineToArgvW(w_cmd_line, argc_ptr)
    if argv_w == nil then return nil, "CommandLineToArgvW failed" end

    local argc = argc_ptr[0]
    local result = {}

    for i = 0, argc - 1 do
        result[i + 1] = util.from_wide(argv_w[i])
    end

    kernel32.LocalFree(argv_w)
    return result
end

M.get_arguments = function()
    local cmd_line_w = kernel32.GetCommandLineW()
    local argc_ptr = ffi.new("int[1]")

    local argv_w = shell32.CommandLineToArgvW(cmd_line_w, argc_ptr)
    if argv_w == nil then return nil end

    local argc = argc_ptr[0]
    local result = {}
    for i = 0, argc - 1 do
        result[i + 1] = util.from_wide(argv_w[i])
    end
    kernel32.LocalFree(argv_w)
    return result
end

return M
