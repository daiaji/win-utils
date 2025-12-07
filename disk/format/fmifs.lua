local ffi = require 'ffi'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local util = require 'win-utils.core.util'

local M = {}

function M.format(drive_letter, fs, label)
    if not drive_letter then return false, "Drive letter required" end
    
    -- [Rufus Strategy] Capture status from callback
    -- Default to false in case FCC_DONE is never received
    local success_status = false
    
    -- Callback must ensure data validity
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        -- FCC_DONE = 11
        if cmd == 11 then 
            if data ~= nil then
                -- data points to a BOOLEAN (byte)
                local res = ffi.cast("BOOLEAN*", data)[0]
                success_status = (res ~= 0)
            end
        end
        return 1 -- TRUE to continue
    end)
    
    local ok, err = pcall(function()
        fmifs.FormatEx(
            util.to_wide(drive_letter), 
            ffi.C.FMIFS_HARDDISK, 
            util.to_wide(fs), 
            util.to_wide(label), 
            1, -- Quick Format
            0, -- Default Cluster
            cb
        )
    end)
    
    cb:free()
    
    if not ok then return false, "FormatEx crashed: " .. tostring(err) end
    if not success_status then return false, "FormatEx reported failure (FCC_DONE=False)" end
    return true
end

function M.check_disk(drive_letter, fs, fix)
    if not drive_letter then return false, "Drive letter required" end
    
    local success_status = false
    
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        if cmd == 11 then -- FCC_DONE
             if data ~= nil then
                local res = ffi.cast("BOOLEAN*", data)[0]
                success_status = (res ~= 0)
            end
        end
        return 1
    end)
    
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
    if not success_status then return false, "Chkdsk reported failure" end
    return true
end

return M