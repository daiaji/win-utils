local M = {}

local LEVELS = { trace = 10, debug = 20, info = 30, warn = 40, error = 50, off = 100 }
local config = {
    level = LEVELS.info,
    file = nil,
    console = false,
    max_bytes = nil,
}

local function level_value(level)
    if type(level) == "number" then return level end
    return LEVELS[tostring(level or "info"):lower()]
end

local function should_log(level)
    local value = level_value(level)
    return value and value >= config.level and config.level < LEVELS.off
end

local function rotate_if_needed(path)
    if not config.max_bytes or config.max_bytes <= 0 then return end
    local f = io.open(path, "rb")
    if not f then return end
    local size = f:seek("end") or 0
    f:close()
    if size < config.max_bytes then return end
    os.remove(path .. ".1")
    os.rename(path, path .. ".1")
end

local function format_line(level, message, fields)
    local parts = {
        os.date("!%Y-%m-%dT%H:%M:%SZ"),
        tostring(level):upper(),
        tostring(message or ""),
    }
    if fields then
        for k, v in pairs(fields) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    end
    return table.concat(parts, " ") .. "\n"
end

function M.configure(opts)
    opts = opts or {}
    if opts.level ~= nil then
        local value = level_value(opts.level)
        if not value then return false, "unknown log level: " .. tostring(opts.level) end
        config.level = value
    end
    if opts.file ~= nil then config.file = opts.file end
    if opts.console ~= nil then config.console = not not opts.console end
    if opts.max_bytes ~= nil then config.max_bytes = tonumber(opts.max_bytes) end
    return true
end

function M.get_config()
    return {
        level = config.level,
        file = config.file,
        console = config.console,
        max_bytes = config.max_bytes,
    }
end

function M.write(level, message, fields)
    if not should_log(level) then return true end
    local line = format_line(level, message, fields)
    if config.console then io.stderr:write(line) end
    if config.file then
        rotate_if_needed(config.file)
        local f, err = io.open(config.file, "ab")
        if not f then return false, err end
        f:write(line)
        f:close()
    end
    return true
end

function M.trace(message, fields) return M.write("trace", message, fields) end
function M.debug(message, fields) return M.write("debug", message, fields) end
function M.info(message, fields) return M.write("info", message, fields) end
function M.warn(message, fields) return M.write("warn", message, fields) end
function M.error(message, fields) return M.write("error", message, fields) end

function M.scoped(scope)
    return setmetatable({ scope = scope }, {
        __index = function(_, key)
            if not LEVELS[key] then return nil end
            return function(_, message, fields)
                fields = fields or {}
                fields.scope = scope
                return M.write(key, message, fields)
            end
        end,
    })
end

M.LEVELS = LEVELS

return M
