local ffi = require 'ffi'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local util = require 'win-utils.core.util'

local M = {}

function M.format(drive_letter, fs, label)
    if not drive_letter then return false, "Drive letter required" end
    
    local success_status = false
    local error_detail = nil
    
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        if cmd == 11 then -- FCC_DONE
            if data ~= nil then
                local res = ffi.cast("BOOLEAN*", data)[0]
                success_status = (res ~= 0)
            end
        -- Capture common failures
        elseif cmd == 6 then error_detail = "Access Denied (FCC_INSUFFICIENT_RIGHTS)"
        elseif cmd == 7 then error_detail = "Write Protected (FCC_WRITE_PROTECTED)"
        elseif cmd == 16 then error_detail = "Volume In Use (FCC_VOLUME_IN_USE)"
        end
        return 1
    end)
    
    local ok, err = pcall(function()
        fmifs.FormatEx(
            util.to_wide(drive_letter), 
            ffi.C.FMIFS_HARDDISK, -- Corrected constant
            util.to_wide(fs), 
            util.to_wide(label), 
            1, -- Quick Format
            0, -- Default Cluster
            cb
        )
    end)
    
    cb:free()
    
    if not ok then return false, "FormatEx crashed: " .. tostring(err) end
    if not success_status then 
        return false, "FormatEx failed: " .. (error_detail or "FCC_DONE=False") 
    end
    return true
end

function M.check_disk(drive_letter, fs, fix)
    if not drive_letter then return false, "Drive letter required" end
    
    local success_status = false
    
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        if cmd == 11 then 
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