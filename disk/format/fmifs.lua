local ffi = require 'ffi'
local jit = require 'jit'
local util = require 'win-utils.util'
local fmifs = require 'ffi.req' 'Windows.sdk.fmifs'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'

ffi.cdef[[
    typedef BOOLEAN (__stdcall *PENABLE_VOLUME_COMPRESSION)(
        LPCWSTR DriveRoot,
        DWORD   CompressionType
    );
]]

local M = {}

-- [SAFETY] Safe Callback Wrapper
-- Prevents Lua errors from crashing the C stack across FFI boundaries
local function create_safe_callback(user_cb)
    if not user_cb then return nil end
    
    return ffi.cast("PFILE_SYSTEM_CALLBACK", function(cmd, action, pData)
        -- 1. Disable JIT for safety in callbacks
        jit.off()
        
        local status, result = xpcall(function()
            local percent = 0
            local msg = nil
            
            -- Parse Data based on Command
            if (cmd == fmifs.C.FCC_PROGRESS or cmd == fmifs.C.FCC_CHECKDISK_PROGRESS) and pData ~= nil then
                percent = ffi.cast("uint32_t*", pData)[0]
                return user_cb(cmd, percent)
                
            elseif cmd == fmifs.C.FCC_OUTPUT and pData ~= nil then
                local text_out = ffi.cast("PTEXTOUTPUT", pData)
                if text_out.Output ~= nil then
                    msg = util.from_wide(text_out.Output)
                end
                return user_cb(cmd, msg)
            else
                -- Forward other commands
                return user_cb(cmd, nil)
            end
        end, debug.traceback)
        
        -- 2. Restore JIT
        jit.on()
        
        if not status then
            -- Log error to stderr but don't crash
            io.stderr:write("FMIFS Callback Error: " .. tostring(result) .. "\n")
            return 0 -- Return FALSE to stop formatting
        end
        
        return result and 1 or 0
    end)
end

function M.format(drive_letter, fs_name, label, quick, cluster_size, callback_func)
    local root = util.to_wide(drive_letter .. ":\\")
    local fs = util.to_wide(fs_name)
    local lab = util.to_wide(label)
    
    local cb = create_safe_callback(callback_func)
    
    -- Anchor callback is handled by ffi.cast return being held in 'cb' local var
    -- until function returns. Since FormatEx is synchronous, this is safe.
    
    fmifs.FormatEx(root, fmifs.C.FMIFS_HARDDISK, fs, lab, quick and 1 or 0, cluster_size or 0, cb)
    
    if cb then cb:free() end
    return true
end

function M.enable_compression(drive_letter)
    -- [CHANGED] Use explicit kernel32 binding and Wide Char API to comply with
    -- Guideline #3 (Explicit library loading) and available bindings.
    
    local w_module_name = util.to_wide("fmifs.dll")
    
    local hModule = kernel32.GetModuleHandleW(w_module_name)
    if hModule == nil then
        hModule = kernel32.LoadLibraryW(w_module_name)
    end
    if hModule == nil then return false, "Could not load fmifs.dll" end
    
    -- GetProcAddress is only available in ANSI (LPCSTR), which is standard on Windows even for Wide apps.
    -- Since kernel32.lua binding might not expose ANSI GetProcAddress explicitly, we access it via ffi.C
    -- or check if kernel32.GetProcAddress is available.
    -- Standard kernel32.lua usually only binds Wide functions if minimal.
    -- But GetProcAddress is *always* ANSI for symbol names.
    -- We assume the environment has GetProcAddress available.
    
    local func_ptr = ffi.C.GetProcAddress(hModule, "EnableVolumeCompression")
    if func_ptr == nil then return false, "EnableVolumeCompression not found" end
    
    local EnableVolumeCompression = ffi.cast("PENABLE_VOLUME_COMPRESSION", func_ptr)
    local root = util.to_wide(drive_letter .. ":\\")
    
    -- COMPRESSION_FORMAT_DEFAULT = 1
    return EnableVolumeCompression(root, 1) ~= 0
end

function M.check_disk(drive_letter, fs_name, fix, callback_func)
    local root = util.to_wide(drive_letter .. ":\\")
    local fs = util.to_wide(fs_name)
    
    local cb = create_safe_callback(callback_func)
    
    fmifs.Chkdsk(root, fs, not fix, fix, false, false, false, nil, cb)
    
    if cb then cb:free() end
    return true
end

return M