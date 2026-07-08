local ffi = require 'ffi'
local dns = require 'ffi.req' 'Windows.sdk.dnsapi'
local util = require 'win-utils.core.util'
local M = {}

local function quote_arg(arg)
    arg = tostring(arg)
    if arg == "" then return '""' end
    if not arg:find('[%s"]') then return arg end
    return '"' .. arg:gsub('"', '\\"') .. '"'
end

local function run_netsh(args, opts)
    opts = opts or {}
    if opts.dry_run then return { ok = true, dry_run = true, command = "netsh " .. table.concat(args, " ") } end

    local proc = require 'win-utils.process.init'
    local result, err = proc.exec({
        file = "netsh.exe",
        args = args,
        show = 0,
        capture_stdout = true,
        capture_stderr = true,
        timeout = opts.timeout or 15000,
    })
    if not result then return nil, err end
    if result.exit_code ~= 0 then
        return nil, result.stderr ~= "" and result.stderr or result.stdout
    end
    return result
end

function M.flush() 
    local res = dns.DnsFlushResolverCache()
    if res == 0 then return false, util.last_error("DnsFlushResolverCache failed") end
    return true
end

function M.set_servers(adapter, servers, opts)
    opts = opts or {}
    if not adapter or adapter == "" then return nil, "adapter name required" end
    if type(servers) ~= "table" or #servers == 0 then return nil, "servers table required" end

    local first = run_netsh({
        "interface", "ip", "set", "dns",
        "name=" .. quote_arg(adapter),
        "source=static",
        "addr=" .. tostring(servers[1]),
        "register=primary",
    }, opts)
    if not first or opts.dry_run then return first end

    for i = 2, #servers do
        local ok, err = run_netsh({
            "interface", "ip", "add", "dns",
            "name=" .. quote_arg(adapter),
            "addr=" .. tostring(servers[i]),
            "index=" .. tostring(i),
        }, opts)
        if not ok then return nil, err end
    end
    return first
end

return M
