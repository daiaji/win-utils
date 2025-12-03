local ffi = require 'ffi'
local util = require 'win-utils.util'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

local M = {}

-- Safe callback wrapper (Prevents JIT crashes in callbacks)
local function wrap_cb(user_cb)
    if not user_cb then return ffi.cast("PFILE_SYSTEM_CALLBACK", function() return 1 end) end
    return ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, act, data)
        require("jit").off()
        local ok, res = pcall(function()
            if (cmd==0 or cmd==18) and data~=nil then -- PROGRESS
                return user_cb(cmd, ffi.cast("uint32_t*", data)[0])
            elseif cmd==20 and data~=nil then -- OUTPUT
                local txt = ffi.cast("PTEXTOUTPUT", data)
                return user_cb(cmd, txt.Output and util.from_wide(txt.Output))
            end
            return user_cb(cmd, nil)
        end)
        require("jit").on()
        return ok and (res and 1 or 0) or 0
    end)
end

function M.format(drive_letter, fs, label, quick, cluster, cb)
    local root = util.to_wide(drive_letter .. ":\\")
    local wfs = util.to_wide(fs)
    local wlab = util.to_wide(label)
    local cbf = wrap_cb(cb)
    
    fmifs.FormatEx(root, fmifs.C.FMIFS_HARDDISK, wfs, wlab, quick and 1 or 0, cluster or 0, cbf)
    cbf:free()
    return true
end

function M.check_disk(drive_letter, fs, fix, cb)
    local root = util.to_wide(drive_letter .. ":\\")
    local wfs = util.to_wide(fs)
    local cbf = wrap_cb(cb)
    
    fmifs.Chkdsk(root, wfs, not fix, fix, false, false, false, nil, cbf)
    cbf:free()
    return true
end

function M.enable_compression(drive_letter)
    -- Load Library Explicitly
    local hMod = kernel32.LoadLibraryW(util.to_wide("fmifs.dll"))
    if not hMod then return false end
    
    -- GetProcAddress (Standard Kernel32 API, safe to use via ffi.C if loaded, but safer via kernel32 lib)
    -- kernel32.lua typically binds GetProcAddress. If not, we use ffi.C.GetProcAddress
    local addr = kernel32.GetProcAddress(hMod, "EnableVolumeCompression")
    if addr == nil then 
        kernel32.FreeLibrary(hMod)
        return false 
    end
    
    local func = ffi.cast("BOOLEAN (__stdcall *)(LPCWSTR, DWORD)", addr)
    local res = func(util.to_wide(drive_letter..":\\"), 1) -- COMPRESSION_FORMAT_DEFAULT
    
    kernel32.FreeLibrary(hMod)
    return res ~= 0
end

return M