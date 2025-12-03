local ffi = require 'ffi'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local util = require 'win-utils.util'

local M = {}

function M.create(opt)
    ole32.CoInitialize(nil)
    local ppL = ffi.new("void*[1]")
    if ole32.CoCreateInstance(shell32.CLSID_ShellLink, nil, 1, shell32.IID_IShellLinkW, ppL) < 0 then 
        ole32.CoUninitialize(); return false 
    end
    
    local pL = ffi.cast("IShellLinkW*", ppL[0])
    if opt.target then pL.lpVtbl.SetPath(pL, util.to_wide(opt.target)) end
    if opt.args then pL.lpVtbl.SetArguments(pL, util.to_wide(opt.args)) end
    if opt.work_dir then pL.lpVtbl.SetWorkingDirectory(pL, util.to_wide(opt.work_dir)) end
    
    local ppF = ffi.new("void*[1]")
    local res = false
    if pL.lpVtbl.QueryInterface(pL, shell32.IID_IPersistFile, ppF) >= 0 then
        local pF = ffi.cast("IPersistFile*", ppF[0])
        res = (pF.lpVtbl.Save(pF, util.to_wide(opt.path), 1) >= 0)
        pF.lpVtbl.Release(pF)
    end
    pL.lpVtbl.Release(pL)
    ole32.CoUninitialize()
    return res
end

return M