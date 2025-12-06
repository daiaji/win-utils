local ffi = require 'ffi'
local bit = require 'bit'
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

-- Alias for backward compatibility
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

-- ========================================================================
-- Coreutils: Shell Execution
-- ========================================================================

-- [exec] Execute file, URL, or open directory using Shell API
-- In WinPE (System Authority), this simply launches the process.
-- @param path: Executable, Document, URL, or Directory path.
-- @param args: (Optional) Arguments string.
-- @param show: (Optional) SW_SHOW* constant (default: 1).
-- @param verb: (Optional) "open", "edit", "print", etc. Default is based on file type.
function M.exec(path, args, show, verb)
    local info = ffi.new("SHELLEXECUTEINFOW")
    info.cbSize = ffi.sizeof(info)
    info.fMask = 0x40 -- SEE_MASK_NOCLOSEPROCESS (populate hProcess)
    
    local w_path = util.to_wide(path)
    local w_args = args and util.to_wide(args) or nil
    local w_verb = verb and util.to_wide(verb) or nil
    
    info.lpFile = w_path
    info.lpParameters = w_args
    info.lpVerb = w_verb
    info.nShow = show or 1 -- SW_SHOWNORMAL
    
    -- GC Anchors
    local _ = {w_path, w_args, w_verb}
    
    local res = shell32.ShellExecuteExW(info) ~= 0
    
    -- If successful and we got a process handle, close it to avoid leaks
    -- (We don't return the handle as this function is fire-and-forget style like 'start')
    if info.hProcess ~= nil then 
        kernel32.CloseHandle(info.hProcess) 
    end
    
    return res
end

-- [restart_self] Helper to restart current script/exe
function M.restart_self()
    local my_args = M.get_args()
    if #my_args == 0 then return false end
    
    local exe = my_args[1]
    local params_tbl = {}
    
    for i=2, #my_args do
        local a = my_args[i]
        if a:find(" ") and not a:match('^".*"$') then 
            a = '"' .. a .. '"' 
        end
        table.insert(params_tbl, a)
    end
    
    local params = table.concat(params_tbl, " ")
    
    -- Use M.exec to launch self
    local ok = M.exec(exe, params)
    
    if ok then
        -- Exit current process
        kernel32.ExitProcess(0)
    end
    return ok
end

return M