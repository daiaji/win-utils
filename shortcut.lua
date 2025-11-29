local ffi = require 'ffi'
local bit = require 'bit'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
-- [CHANGED] shell32 now exports GUIDs in its table
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local util = require 'win-utils.util'

local M = {}

function M.create(opt)
    local hr = ole32.CoInitialize(nil)
    if hr < 0 and hr ~= 0x80010106 then return false, "CoInitialize failed: " .. hr end

    local needs_uninit = (hr == 0 or hr == 1)
    local function cleanup()
        if needs_uninit then ole32.CoUninitialize() end
    end

    -- [CHANGED] Use GUIDs from shell32 bindings
    local CLSID_SL           = shell32.CLSID_ShellLink
    local IID_SL             = shell32.IID_IShellLinkW
    local IID_PF             = shell32.IID_IPersistFile

    local ppL                = ffi.new("void*[1]")

    local status, res_or_err = pcall(function()
        if ole32.CoCreateInstance(CLSID_SL, nil, 1, IID_SL, ppL) < 0 then
            return false, "CoCreateInstance failed"
        end

        local pL = ffi.cast("IShellLinkW*", ppL[0])

        if opt.target then pL.lpVtbl.SetPath(pL, util.to_wide(opt.target)) end
        if opt.args then pL.lpVtbl.SetArguments(pL, util.to_wide(opt.args)) end
        if opt.work_dir then pL.lpVtbl.SetWorkingDirectory(pL, util.to_wide(opt.work_dir)) end
        if opt.desc then pL.lpVtbl.SetDescription(pL, util.to_wide(opt.desc)) end

        local ppF = ffi.new("void*[1]")
        local result = true
        local err_msg = nil

        if pL.lpVtbl.QueryInterface(pL, IID_PF, ppF) >= 0 then
            local pF = ffi.cast("IPersistFile*", ppF[0])
            if pF.lpVtbl.Save(pF, util.to_wide(opt.path), 1) < 0 then
                result = false
                err_msg = "IPersistFile::Save failed"
            end
            pF.lpVtbl.Release(pF)
        else
            result = false
            err_msg = "QueryInterface(IPersistFile) failed"
        end

        pL.lpVtbl.Release(pL)
        return result, err_msg
    end)

    cleanup()

    if not status then return false, res_or_err end
    return res_or_err
end

return M
