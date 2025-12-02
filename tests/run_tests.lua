local luaunit = require('luaunit')

-- Force flush stdout to ensure logs appear in CI immediately
io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

-- [CHANGED] Simplified test runner:
-- 1. Relies on LUA_PATH being set correctly (via CI or dev environment)
-- 2. Uses 'require' instead of 'dofile' + path math
-- 3. Just lists modules to run

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