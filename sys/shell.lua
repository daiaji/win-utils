local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- 解析指定的命令行字符串
function M.parse_cmdline(cmd_line)
    if not cmd_line or cmd_line == "" then return {} end
    
    local num = ffi.new("int[1]")
    local args_w = shell32.CommandLineToArgvW(util.to_wide(cmd_line), num)
    
    if args_w == nil then return {} end
    
    local res = {}
    for i = 0, num[0] - 1 do
        table.insert(res, util.from_wide(args_w[i]))
    end
    
    kernel32.LocalFree(args_w)
    return res
end

-- [Restored] 获取并解析当前进程的命令行参数
function M.get_args()
    local cmd = kernel32.GetCommandLineW()
    if cmd == nil then return {} end
    
    local num = ffi.new("int[1]")
    local args_w = shell32.CommandLineToArgvW(cmd, num)
    
    if args_w == nil then return {} end
    
    local res = {}
    for i = 0, num[0] - 1 do
        table.insert(res, util.from_wide(args_w[i]))
    end
    
    kernel32.LocalFree(args_w)
    return res
end

return M