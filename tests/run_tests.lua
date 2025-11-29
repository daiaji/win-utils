local luaunit = require('luaunit')

-- Force flush stdout to ensure logs appear in CI immediately
io.stdout:setvbuf('no')

-- List of spec modules to run
local specs = {
    "win-utils.tests.core_spec", -- [ACTIVATED] Now checking FS, Registry, Disk, etc.
    "win-utils.tests.proc_spec",
}

print("=== Running Win-Utils Test Suite ===")
for _, spec in ipairs(specs) do
    local ok, err = pcall(require, spec)
    if not ok then
        print("Error loading spec: " .. spec)
        print(err)
        os.exit(1)
    end
end

os.exit(luaunit.LuaUnit.run())
