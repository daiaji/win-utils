local luaunit = require('luaunit')

-- Force flush stdout to ensure logs appear in CI immediately
io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

-- List of spec modules to run
-- Since we added stage/tests/?.lua to LUA_PATH, simple require works
local specs = {
    "core_spec",
    "process_spec",
}

print("=== Running Win-Utils Test Suite ===")
for _, spec in ipairs(specs) do
    print("Loading spec module: " .. spec)
    require(spec)
end

os.exit(luaunit.LuaUnit.run())