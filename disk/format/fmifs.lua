local ffi = require 'ffi'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local util = require 'win-utils.core.util'

local M = {}

-- 防止 JIT 在回调中崩溃的安全包装
local function wrap_cb()
    return ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        return 1 -- TRUE to continue
    end)
end

function M.format(drive_letter, fs, label)
    if not drive_letter then return false, "Drive letter required" end
    
    local cb = wrap_cb()
    -- FormatEx 返回 void，无法通过返回值判断成败。
    -- 但如果参数错误（如盘符不存在），可能会导致异常。
    -- 使用 pcall 保护调用防止崩坏。
    local ok, err = pcall(function()
        fmifs.FormatEx(
            util.to_wide(drive_letter), 
            fmifs.C.FMIFS_HARDDISK, 
            util.to_wide(fs), 
            util.to_wide(label), 
            1, -- Quick Format
            0, -- Default Cluster
            cb
        )
    end)
    
    cb:free()
    
    if not ok then return false, "FormatEx crashed: " .. tostring(err) end
    return true
end

function M.check_disk(drive_letter, fs, fix)
    if not drive_letter then return false, "Drive letter required" end
    
    local cb = wrap_cb()
    local ok, err = pcall(function()
        fmifs.Chkdsk(
            util.to_wide(drive_letter), 
            util.to_wide(fs), 
            not fix, -- CheckOnly
            fix,     -- FixErrors
            false,   -- RecoverBadSectors
            false,   -- Extended
            false,   -- Resize
            nil,     -- LogFile
            cb
        )
    end)
    
    cb:free()
    
    if not ok then return false, "Chkdsk crashed: " .. tostring(err) end
    return true
end

return M