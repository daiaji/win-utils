-- Offline test runner for specs that do not require Windows APIs or luaunit.
local function setup_path()
    local sep = package.config:sub(1, 1)
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
        package.path = table.concat({
            parent .. "?.lua",
            parent .. "?" .. sep .. "init.lua",
            root .. "?.lua",
            root .. "?" .. sep .. "init.lua",
            package.path,
        }, ";")
    end
end

setup_path()

local lu = {}

local function fail(message)
    error(message or "assertion failed", 2)
end

function lu.assertNil(value, message)
    if value ~= nil then fail(message or "expected nil") end
end

function lu.assertTrue(value, message)
    if value ~= true then fail(message or "expected true") end
end

function lu.assertEquals(actual, expected, message)
    if actual ~= expected then
        fail(message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)))
    end
end

package.loaded.luaunit = lu

local suites = {
    "win-utils.tests.disk_safety_spec",
}

for _, suite in ipairs(suites) do
    require(suite)
end

local total = 0
local failed = 0

for name, suite in pairs(_G) do
    if type(name) == "string" and name:match("^Test") and type(suite) == "table" then
        for test_name, test_fn in pairs(suite) do
            if type(test_name) == "string" and test_name:match("^test") and type(test_fn) == "function" then
                total = total + 1
                local ok, err = pcall(test_fn, suite)
                if ok then
                    print("PASS " .. name .. ":" .. test_name)
                else
                    failed = failed + 1
                    print("FAIL " .. name .. ":" .. test_name .. " - " .. tostring(err))
                end
            end
        end
    end
end

print(string.format("Offline tests: %d run, %d failed", total, failed))
os.exit(failed == 0 and 0 or 1)
