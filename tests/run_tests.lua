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
    local source = debug.getinfo(1).source
    local root = source:match("@(.*[\\/])tests[\\/]")
    if not root and source:match("^@tests[\\/]") then
        root = "." .. sep
    end
    if root then
        local parent = root:gsub("[\\/][^\\/]+[\\/]$", sep)
        if parent == root then
            parent = ".." .. sep
        end
        local searchers = package.searchers or package.loaders
        local function vendor_searcher(modname)
            local rel
            if modname:match("^ext%.") then
                rel = "vendor" .. sep .. "lua-ext" .. sep .. modname:sub(5):gsub("%.", sep) .. ".lua"
            elseif modname:match("^ffi%.") then
                rel = "vendor" .. sep .. "lua-ffi-bindings" .. sep .. modname:sub(5):gsub("%.", sep) .. ".lua"
            else
                return "\n\tno win-utils vendor mapping for " .. modname
            end

            local path = root .. rel
            local chunk, err = loadfile(path)
            if chunk then return chunk end
            return "\n\tno file '" .. path .. "': " .. tostring(err)
        end

        table.insert(searchers, 1, vendor_searcher)
        -- Add project root to path so 'require "win-utils"' works
        package.path = parent .. "?.lua;" .. parent .. "?" .. sep .. "init.lua;" .. root .. "?.lua;" .. root .. "?" .. sep .. "init.lua;" .. package.path
    end
end
setup_path()

local luaunit = require('luaunit')

print("=== Win-Utils Test Suite (Strictly Complete) ===")
print("OS: " .. ffi.os .. " / Arch: " .. ffi.arch)

-- Load Suites
require 'win-utils.tests.core_spec'
require 'win-utils.tests.disk_safety_spec'
-- require 'win-utils.tests.fs_spec' -- [DEPRECATED] Moved to VHD Integration Test
require 'win-utils.tests.process_spec'
require 'win-utils.tests.disk_spec'
require 'win-utils.tests.net_spec'
require 'win-utils.tests.sys_spec'

-- Run Tests
os.exit(luaunit.LuaUnit.run())
