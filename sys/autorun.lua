local reg = require 'win-utils.reg.init'

local M = {}

local BASE = [[Software\Microsoft\Windows\CurrentVersion]]

local function run_path(opts)
    opts = opts or {}
    local root = opts.machine and "HKLM" or "HKCU"
    local key = opts.once and "RunOnce" or "Run"
    return root, BASE .. "\\" .. key
end

function M.list(opts)
    local root, sub = run_path(opts)
    local key, err = reg.open_existing_key(root, sub)
    if not key then return {}, err end
    local values, values_err = key:enum_values({ expand = false })
    key:close()
    return values or {}, values_err
end

function M.set(name, command, opts)
    opts = opts or {}
    if not name or name == "" then return false, "name required" end
    if not command or command == "" then return false, "command required" end
    if opts.dry_run then return { ok = true, dry_run = true, name = name, command = command } end

    local root, sub = run_path(opts)
    local key, err = reg.open_key(root, sub)
    if not key then return false, err end
    local ok, write_err = key:write(name, command, "string")
    key:close()
    return ok, write_err
end

function M.delete(name, opts)
    opts = opts or {}
    if not name or name == "" then return false, "name required" end
    if opts.dry_run then return { ok = true, dry_run = true, name = name } end

    local root, sub = run_path(opts)
    local key = reg.open_existing_key(root, sub, 0x20006)
    if not key then return true end
    local ok, err = key:delete_value(name)
    key:close()
    if not ok and err and err:find("2") then return true end
    return ok, err
end

return M
