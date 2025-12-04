local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local class = require 'win-utils.deps'.class

local Handle = class()
local INVALID = ffi.cast("HANDLE", -1)
local NULL_HANDLE = ffi.cast("HANDLE", 0)

function Handle:init(h, closer)
    self.handle = h
    self.closer = closer or kernel32.CloseHandle
    
    if self:valid() then
        -- FFI GC Anchor
        ffi.gc(self.handle, function(ptr)
            if ptr ~= INVALID and ptr ~= NULL_HANDLE then 
                self.closer(ptr) 
            end
        end)
    end
end

function Handle:valid()
    return self.handle ~= nil and self.handle ~= INVALID and self.handle ~= NULL_HANDLE
end

function Handle:get()
    if not self:valid() then error("Attempt to use invalid handle") end
    return self.handle
end

function Handle:close()
    if self:valid() then
        ffi.gc(self.handle, nil) -- Detach GC
        self.closer(self.handle)
        self.handle = INVALID
        return true
    end
    return false
end

-- 作用域保护
function Handle:scope(func)
    local ok, res, err = pcall(func, self:get())
    self:close()
    if not ok then error(res) end
    return res, err
end

return Handle