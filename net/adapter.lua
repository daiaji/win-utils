local ffi = require 'ffi'
local iphlp = require 'ffi.req' 'Windows.sdk.iphlpapi'
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

local function sock_to_ip(ptr)
    if ptr == nil then return nil end
    local family = ffi.cast("short*", ptr)[0]
    if family == 2 then 
        local sin = ffi.cast("uint8_t*", ptr)
        return string.format("%d.%d.%d.%d", sin[4], sin[5], sin[6], sin[7])
    end
    return nil
end

local function mac_string(adapter)
    local len = tonumber(adapter.PhysicalAddressLength)
    if len <= 0 then return nil end
    local parts = {}
    for i = 0, len - 1 do parts[#parts + 1] = string.format("%02X", adapter.PhysicalAddress[i]) end
    return table.concat(parts, ":")
end

local function if_type_name(if_type)
    local names = {
        [6] = "ethernet",
        [9] = "token_ring",
        [23] = "ppp",
        [24] = "loopback",
        [37] = "atm",
        [71] = "wireless",
        [131] = "tunnel",
        [144] = "ieee1394",
    }
    return names[tonumber(if_type)] or tostring(if_type)
end

function M.list()
    local flags = 0x90 -- INCLUDE_PREFIX | INCLUDE_GATEWAYS
    local sz = ffi.new("ULONG[1]", 15000)
    local buf = ffi.new("uint8_t[?]", sz[0])
    
    local res = iphlp.GetAdaptersAddresses(2, flags, nil, ffi.cast("void*", buf), sz)
    if res == 111 then -- ERROR_BUFFER_OVERFLOW
        buf = ffi.new("uint8_t[?]", sz[0])
        res = iphlp.GetAdaptersAddresses(2, flags, nil, ffi.cast("void*", buf), sz)
    end
    
    if res ~= 0 then return nil, util.last_error("GetAdaptersAddresses") end
    
    local curr = ffi.cast("IP_ADAPTER_ADDRESSES*", buf)
    local list = {}
    
    while curr ~= nil do
        local item = {
            adapter_name = ffi.string(curr.AdapterName),
            if_index = tonumber(curr.IfIndex),
            name = util.from_wide(curr.FriendlyName), 
            desc = util.from_wide(curr.Description),
            status = (tonumber(curr.OperStatus) == 1) and "Up" or "Down",
            mac = mac_string(curr),
            mtu = tonumber(curr.Mtu),
            if_type = tonumber(curr.IfType),
            type = if_type_name(curr.IfType),
            ips = {},
            gateways = {},
            dns = {}
        }
        
        local ua = curr.FirstUnicastAddress
        while ua ~= nil do
            local ip = sock_to_ip(ua.Address.lpSockaddr)
            if ip then
                table.insert(item.ips, ip)
                item.ipv4_prefix_length = tonumber(ua.OnLinkPrefixLength)
                item.dhcp = tonumber(ua.PrefixOrigin) == 3 or tonumber(ua.SuffixOrigin) == 3
            end
            ua = ua.Next
        end
        
        local ga = curr.FirstGatewayAddress
        while ga ~= nil do
            local ip = sock_to_ip(ga.Address.lpSockaddr)
            if ip then table.insert(item.gateways, ip) end
            ga = ga.Next
        end

        local dns = curr.FirstDnsServerAddress
        while dns ~= nil do
            local ip = sock_to_ip(dns.Address.lpSockaddr)
            if ip then table.insert(item.dns, ip) end
            dns = dns.Next
        end

        table.insert(list, item)
        curr = curr.Next
    end
    return list
end

function M.set_ipv4(adapter, opts)
    opts = opts or {}
    if not adapter or adapter == "" then return nil, "adapter name required" end

    if opts.dhcp then
        return run_netsh({ "interface", "ip", "set", "address", "name=" .. quote_arg(adapter), "source=dhcp" }, opts)
    end

    if not opts.address then return nil, "address required unless dhcp = true" end
    if not opts.mask then return nil, "mask required for static IPv4" end
    local args = {
        "interface", "ip", "set", "address",
        "name=" .. quote_arg(adapter),
        "source=static",
        "addr=" .. tostring(opts.address),
        "mask=" .. tostring(opts.mask),
    }
    if opts.gateway then
        table.insert(args, "gateway=" .. tostring(opts.gateway))
        table.insert(args, "gwmetric=" .. tostring(opts.gateway_metric or 1))
    end
    return run_netsh(args, opts)
end

function M.enable(adapter, opts)
    if not adapter or adapter == "" then return nil, "adapter name required" end
    return run_netsh({ "interface", "set", "interface", "name=" .. quote_arg(adapter), "admin=enabled" }, opts)
end

function M.disable(adapter, opts)
    if not adapter or adapter == "" then return nil, "adapter name required" end
    return run_netsh({ "interface", "set", "interface", "name=" .. quote_arg(adapter), "admin=disabled" }, opts)
end

return M
