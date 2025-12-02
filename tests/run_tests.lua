local luaunit = require('luaunit')

-- Force flush stdout to ensure logs appear in CI immediately
io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

-- [CHANGED] Use local path resolution for specs, assuming this script is run from its directory
-- or that specs are adjacent.
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)") or "./"
end
local dir = script_path()

-- List of spec modules to run (filenames relative to this script)
local specs = {
    "core_spec.lua",
    "process_spec.lua",
}

print("=== Running Win-Utils Test Suite ===")
for _, spec in ipairs(specs) do
    local path = dir .. spec
    print("Loading spec: " .. path)
    -- Using dofile to load the test definitions into the global scope
    -- This avoids module caching issues and package path complexity for test files themselves
    dofile(path)
end

os.exit(luaunit.LuaUnit.run())