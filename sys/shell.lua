local ffi = require 'ffi'
local bit = require 'bit'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 解析命令行字符串为参数数组
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

-- [API] 获取当前进程的启动参数
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

-- [API] 弹出文件夹选择对话框
function M.browse_folder(title)
    local bi = ffi.new("BROWSEINFOW")
    bi.ulFlags = 0x41 -- BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
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

-- [API] 执行程序/打开文件 (ShellExecute)
-- @param path: 可执行文件、文档、URL 或 目录
-- @param opts: { args=string, show=int, verb=string, dir=string }
function M.exec(path, opts)
    opts = opts or {}
    local info = ffi.new("SHELLEXECUTEINFOW")
    info.cbSize = ffi.sizeof(info)
    info.fMask = 0x40 -- SEE_MASK_NOCLOSEPROCESS (populate hProcess)
    
    local w_path = util.to_wide(path)
    local w_args = opts.args and util.to_wide(opts.args) or nil
    local w_verb = opts.verb and util.to_wide(opts.verb) or nil
    local w_dir  = opts.dir and util.to_wide(opts.dir) or nil
    
    info.lpFile = w_path
    info.lpParameters = w_args
    info.lpVerb = w_verb
    info.lpDirectory = w_dir
    info.nShow = opts.show or 1 -- SW_SHOWNORMAL
    
    -- GC Anchors
    local _ = {w_path, w_args, w_verb, w_dir}
    
    local res = shell32.ShellExecuteExW(info) ~= 0
    
    if info.hProcess ~= nil then 
        kernel32.CloseHandle(info.hProcess) 
    end
    
    return res
end

-- [API] 重启当前进程
function M.restart_self()
    local my_args = M.get_args()
    if #my_args == 0 then return false end
    
    local exe = my_args[1]
    local params_tbl = {}
    
    for i=2, #my_args do
        local a = my_args[i]
        -- 简单引用处理：如果包含空格且未被引用，则添加引号
        if a:find(" ") and not a:match('^".*"$') then 
            a = '"' .. a .. '"' 
        end
        table.insert(params_tbl, a)
    end
    
    local params = table.concat(params_tbl, " ")
    
    local ok = M.exec(exe, { args = params })
    
    if ok then
        kernel32.ExitProcess(0)
    end
    return ok
end

return M