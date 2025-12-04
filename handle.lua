local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local class = require 'win-utils.deps'.class

local INVALID = ffi.cast("HANDLE", -1)
local NULL_HANDLE = ffi.cast("HANDLE", 0)

local SafeHandle = class()

function SafeHandle:init(handle, closer)
    -- [DEBUG] Enhanced Logging
    -- io.write(string.format("[HANDLE] init entry. Handle: %s\n", tostring(handle)))
    -- io.stdout:flush()
    
    self.handle = handle
    
    -- [CRITICAL FIX] Capture closer in local scope to avoid 'self' capture in GC
    local close_func = closer or kernel32.CloseHandle
    self._closer = close_func 
    
    if self:is_valid() then
        -- FFI GC Anchor
        ffi.gc(self.handle, function(h)
            if h ~= INVALID and h ~= NULL_HANDLE then 
                -- io.write("[HANDLE] GC closing: " .. tostring(h) .. "\n")
                -- io.stdout:flush()
                close_func(h) 
            end
        end)
    else
        -- io.write("[HANDLE] Handle is INVALID or NULL, skipping GC.\n")
        -- io.stdout:flush()
    end
end

function SafeHandle:is_valid()
    return self.handle ~= nil and self.handle ~= INVALID and self.handle ~= NULL_HANDLE
end

function SafeHandle:close()
    if self:is_valid() then
        ffi.gc(self.handle, nil) -- Detach GC
        self._closer(self.handle)
        self.handle = INVALID
        return true
    end
    return false
end

function SafeHandle:get() return self.handle end

-- [FIX] Removed SafeHandle.new to prevent recursion loop with ext.class __call mechanism
-- ext.class automatically provides a .new() method that calls init().
-- Using SafeHandle(h) or SafeHandle:new(h) is sufficient.

-- Guard factory (Alias for instantiation, useful for explicit intent)
function SafeHandle.guard(h, c) return SafeHandle(h, c) end

return SafeHandle