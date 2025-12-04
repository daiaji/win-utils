local ffi = require 'ffi'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local util = require 'win-utils.core.util'
local M = {}
function M.create(path, target)
    ole32.CoInitialize(nil)
    local o = ffi.new("void*[1]")
    ole32.CoCreateInstance(shell32.CLSID_ShellLink, nil, 1, shell32.IID_IShellLinkW, o)
    local sl = ffi.cast("IShellLinkW*", o[0])
    sl.lpVtbl.SetPath(sl, util.to_wide(target))
    sl.lpVtbl.QueryInterface(sl, shell32.IID_IPersistFile, o)
    local pf = ffi.cast("IPersistFile*", o[0])
    pf.lpVtbl.Save(pf, util.to_wide(path), 1)
    pf.lpVtbl.Release(pf); sl.lpVtbl.Release(sl)
    ole32.CoUninitialize()
end
return M