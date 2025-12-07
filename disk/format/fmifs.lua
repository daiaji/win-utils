local ffi = require 'ffi'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local util = require 'win-utils.core.util'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}

-- [RESTORED] Added cluster_size parameter
function M.format(drive_path, fs, label, media_type, cluster_size)
    if not drive_path then return false, "Drive path required" end
    
    local root = drive_path
    if root:sub(-1) == "\\" then root = root:sub(1, -2) end
    
    media_type = media_type or ffi.C.FMIFS_HARDDISK
    local cluster = cluster_size or 0 -- 0 = Default
    
    local success_status = false
    local error_detail = nil
    
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        if cmd == 11 then -- FCC_DONE
            if data ~= nil then
                local res = ffi.cast("BOOLEAN*", data)[0]
                success_status = (res ~= 0)
            end
        elseif cmd == 6 then error_detail = "Access Denied"
        elseif cmd == 7 then error_detail = "Write Protected"
        elseif cmd == 16 then error_detail = "Volume In Use"
        end
        return 1
    end)
    
    local max_retries = 4
    local retry_wait = 3000
    
    for i = 1, max_retries do
        success_status = false
        error_detail = nil
        kernel32.SetLastError(0)
        
        local ok, err = pcall(function()
            fmifs.FormatEx(
                util.to_wide(root), 
                media_type, 
                util.to_wide(fs), 
                util.to_wide(label), 
                1, -- Quick Format
                cluster, -- [RESTORED]
                cb
            )
        end)
        
        if ok and success_status then
            cb:free()
            return true
        end
        
        if i < max_retries then
            kernel32.Sleep(retry_wait)
        else
            cb:free()
            if not ok then return false, "FormatEx crashed: " .. tostring(err) end
            return false, "FormatEx failed: " .. (error_detail or "FCC_DONE=False")
        end
    end
end

function M.check_disk(drive_letter, fs, fix)
    if not drive_letter then return false, "Drive letter required" end
    local success_status = false
    local cb = ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, data)
        if cmd == 11 and data ~= nil then
            success_status = (ffi.cast("BOOLEAN*", data)[0] ~= 0)
        end
        return 1
    end)
    
    local ok, err = pcall(function()
        fmifs.Chkdsk(util.to_wide(drive_letter), util.to_wide(fs), not fix, fix, false, false, false, nil, cb)
    end)
    cb:free()
    
    if not ok then return false, "Chkdsk crashed: " .. tostring(err) end
    if not success_status then return false, "Chkdsk reported failure" end
    return true
end

return M