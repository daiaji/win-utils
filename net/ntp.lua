local M = {}

function M.sync(server, opts)
    opts = opts or {}
    server = server or opts.server or "time.windows.com"

    local commands = {
        { "w32tm.exe", "/config", "/manualpeerlist:" .. server, "/syncfromflags:manual", "/update" },
        { "w32tm.exe", "/resync", "/force" },
    }

    if opts.dry_run then
        return { ok = true, dry_run = true, commands = commands }
    end

    local proc = require 'win-utils.process.init'
    local results = {}
    for _, cmd in ipairs(commands) do
        local result, err = proc.exec({
            file = cmd[1],
            args = { unpack(cmd, 2) },
            show = 0,
            capture_stdout = true,
            capture_stderr = true,
            timeout = opts.timeout or 30000,
        })
        if not result then return nil, err end
        table.insert(results, result)
        if result.exit_code ~= 0 then
            return nil, result.stderr ~= "" and result.stderr or result.stdout
        end
    end
    return { ok = true, results = results }
end

return M
