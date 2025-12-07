-- Global Test Runner
local ffi = require 'ffi'

-- [CRITICAL] Disable JIT for FFI stability during heavy tests (Callbacks/Enumerations)
if jit then 
    jit.off() 
    jit.flush() 
end

-- Polyfill for environments without 'win-utils' in package.path correctly setup
local function setup_path()
    local sep = package.config:sub(1,1)
    local root = debug.getinfo(1).source:match("@(.*[\\/])tests[\\/]") 
    if root then
        -- Add project root to path so 'require "win-utils"' works
        package.path = root .. "?.lua;" .. root .. "?" .. sep .. "init.lua;" .. package.path
    end
end
setup_path()

local luaunit = require('luaunit')

print("=== Win-Utils Test Suite (Strictly Complete) ===")
print("OS: " .. ffi.os .. " / Arch: " .. ffi.arch)

-- Load Suites
require 'win-utils.tests.core_spec'
-- require 'win-utils.tests.fs_spec' -- [DEPRECATED] Moved to VHD Integration Test
require 'win-utils.tests.process_spec'
require 'win-utils.tests.disk_spec'
require 'win-utils.tests.net_spec'
require 'win-utils.tests.sys_spec'

-- Run Tests
os.exit(luaunit.LuaUnit.run())