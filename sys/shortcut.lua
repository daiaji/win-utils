local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 创建快捷方式 (.lnk)
-- @param path: .lnk 文件路径
-- @param opts: { target="...", args="...", work_dir="...", desc="...", icon="...", icon_idx=0, show=1 }
function M.create(path, opts)
    if type(opts) ~= "table" then return false, "Options table required" end
    if not opts.target then return false, "Target required" end

    ole32.CoInitialize(nil)
    
    local ppObj = ffi.new("void*[1]")
    local hr = ole32.CoCreateInstance(shell32.CLSID_ShellLink, nil, 1, shell32.IID_IShellLinkW, ppObj)
    if hr < 0 then ole32.CoUninitialize(); return false, "CoCreateInstance failed" end
    
    local sl = ffi.cast("IShellLinkW*", ppObj[0])
    
    -- 设置属性
    sl.lpVtbl.SetPath(sl, util.to_wide(opts.target))
    if opts.args then sl.lpVtbl.SetArguments(sl, util.to_wide(opts.args)) end
    if opts.work_dir then sl.lpVtbl.SetWorkingDirectory(sl, util.to_wide(opts.work_dir)) end
    if opts.desc then sl.lpVtbl.SetDescription(sl, util.to_wide(opts.desc)) end
    if opts.show then sl.lpVtbl.SetShowCmd(sl, opts.show) end
    if opts.icon then sl.lpVtbl.SetIconLocation(sl, util.to_wide(opts.icon), opts.icon_idx or 0) end
    
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