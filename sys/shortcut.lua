local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.core.util'

local M = {}

-- opt: { target="...", args="...", dir="...", desc="..." }
function M.create(path, opt)
    -- 兼容旧接口：如果是字符串，则视为 target
    local target = type(opt) == "string" and opt or opt.target
    local args = type(opt) == "table" and opt.args or nil
    local dir = type(opt) == "table" and opt.work_dir or nil
    local desc = type(opt) == "table" and opt.desc or nil

    ole32.CoInitialize(nil)
    
    local ppObj = ffi.new("void*[1]")
    local hr = ole32.CoCreateInstance(shell32.CLSID_ShellLink, nil, 1, shell32.IID_IShellLinkW, ppObj)
    if hr < 0 then ole32.CoUninitialize(); return false, "CoCreateInstance failed" end
    
    local sl = ffi.cast("IShellLinkW*", ppObj[0])
    
    -- 设置属性
    if target then sl.lpVtbl.SetPath(sl, util.to_wide(target)) end
    if args then sl.lpVtbl.SetArguments(sl, util.to_wide(args)) end
    if dir then sl.lpVtbl.SetWorkingDirectory(sl, util.to_wide(dir)) end
    if desc then sl.lpVtbl.SetDescription(sl, util.to_wide(desc)) end
    
    -- 保存
    local res = false
    local ppPf = ffi.new("void*[1]")
    if sl.lpVtbl.QueryInterface(sl, shell32.IID_IPersistFile, ppPf) >= 0 then
        local pf = ffi.cast("IPersistFile*", ppPf[0])
        if pf.lpVtbl.Save(pf, util.to_wide(path), 1) >= 0 then
            res = true
        end
        pf.lpVtbl.Release(pf)
    end
    
    sl.lpVtbl.Release(sl)
    ole32.CoUninitialize()
    
    return res
end

return M