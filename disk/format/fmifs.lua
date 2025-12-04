local ffi = require 'ffi'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local util = require 'win-utils.core.util'

local M = {}

-- 防止 JIT 在回调中崩溃的安全包装
-- FMIFS 回调签名: BOOLEAN (__stdcall *PFILE_SYSTEM_CALLBACK)(int Command, DWORD Action, void* pData);
local function wrap_cb()
    return ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        -- 在此处可以处理进度 (cmd==0) 或 输出 (cmd==20)
        -- 为保持精简，默认返回 TRUE (1) 继续执行
        return 1
    end)
end

function M.format(drive_letter, fs, label)
    local cb = wrap_cb()
    -- FormatEx(DriveRoot, MediaType, FileSystemName, Label, Quick, ClusterSize, Callback)
    -- MediaType: 0x0C (HardDisk)
    fmifs.FormatEx(
        util.to_wide(drive_letter), 
        fmifs.C.FMIFS_HARDDISK, 
        util.to_wide(fs), 
        util.to_wide(label), 
        1, -- Quick Format
        0, -- Default Cluster
        cb
    )
    cb:free()
    return true
end

function M.check_disk(drive_letter, fs, fix)
    local cb = wrap_cb()
    -- Chkdsk(DriveRoot, FileSystemName, CheckOnly, FixErrors, RecoverBad, Extended, Resize, LogFile, Callback)
    fmifs.Chkdsk(
        util.to_wide(drive_letter), 
        util.to_wide(fs), 
        not fix, -- CheckOnly: if fixing, checkOnly is false
        fix,     -- FixErrors
        false,   -- RecoverBadSectors
        false,   -- Extended
        false,   -- Resize
        nil,     -- LogFile
        cb
    )
    cb:free()
    return true
end

return M