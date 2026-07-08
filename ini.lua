local M = {}

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

function M.parse(text)
    local data = {}
    local section = data
    local section_name = nil

    for line in tostring(text or ""):gmatch("([^\r\n]*)\r?\n?") do
        if line == "" and text:sub(-1) ~= "\n" then break end
        local stripped = trim(line)
        if stripped ~= "" and not stripped:match("^[;#]") then
            local name = stripped:match("^%[(.-)%]$")
            if name then
                section_name = trim(name)
                data[section_name] = data[section_name] or {}
                section = data[section_name]
            else
                local key, value = stripped:match("^([^=]+)=(.*)$")
                if key then
                    section[trim(key)] = trim(value)
                else
                    section[stripped] = true
                end
            end
        end
        if line == "" and text == "" then break end
    end

    return data
end

function M.encode(data)
    local lines = {}
    local root_keys = {}
    local sections = {}

    for k, v in pairs(data or {}) do
        if type(v) == "table" then sections[#sections + 1] = k else root_keys[#root_keys + 1] = k end
    end
    table.sort(root_keys)
    table.sort(sections)

    for _, key in ipairs(root_keys) do
        lines[#lines + 1] = tostring(key) .. "=" .. tostring(data[key])
    end
    if #root_keys > 0 and #sections > 0 then lines[#lines + 1] = "" end

    for si, section in ipairs(sections) do
        lines[#lines + 1] = "[" .. tostring(section) .. "]"
        local keys = {}
        for k in pairs(data[section]) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, key in ipairs(keys) do
            lines[#lines + 1] = tostring(key) .. "=" .. tostring(data[section][key])
        end
        if si < #sections then lines[#lines + 1] = "" end
    end

    return table.concat(lines, "\r\n") .. "\r\n"
end

function M.load(path, opts)
    local fs = require 'win-utils.fs.init'
    local data, err = fs.read(path, opts)
    if not data then return nil, err end
    return M.parse(data)
end

function M.save(path, data, opts)
    local fs = require 'win-utils.fs.init'
    return fs.write(path, M.encode(data), opts)
end

function M.get(data, section, key, default)
    local target = section and data[section] or data
    if type(target) ~= "table" then return default end
    local value = target[key]
    if value == nil then return default end
    return value
end

function M.set(data, section, key, value)
    if section then
        data[section] = data[section] or {}
        data[section][key] = value
    else
        data[key] = value
    end
    return data
end

return M
