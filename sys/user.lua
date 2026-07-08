local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local secur32 = require 'ffi.req' 'Windows.sdk.secur32'
local util = require 'win-utils.core.util'
local token = require 'win-utils.process.token'

local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local M = {}

local ComputerNameDnsHostname = 1
local ComputerNameDnsDomain = 2
local ComputerNameDnsFullyQualified = 3

local function read_sized_string(fn, initial)
    local size = ffi.new('DWORD[1]', initial or 256)
    local buf = ffi.new('wchar_t[?]', size[0])
    if fn(buf, size) ~= 0 then return util.from_wide(buf) end
    if kernel32.GetLastError() ~= 234 then return nil, util.last_error() end
    buf = ffi.new('wchar_t[?]', size[0] + 1)
    if fn(buf, size) == 0 then return nil, util.last_error() end
    return util.from_wide(buf)
end

function M.name()
    return read_sized_string(function(buf, size) return advapi32.GetUserNameW(buf, size) end, 256)
end

function M.full_name(format)
    local fmt = format or secur32.NameSamCompatible
    local size = ffi.new('ULONG[1]', 256)
    local buf = ffi.new('wchar_t[?]', size[0])
    if secur32.GetUserNameExW(fmt, buf, size) ~= 0 then return util.from_wide(buf) end
    if kernel32.GetLastError() ~= 234 then return nil, util.last_error() end
    buf = ffi.new('wchar_t[?]', size[0] + 1)
    if secur32.GetUserNameExW(fmt, buf, size) == 0 then return nil, util.last_error() end
    return util.from_wide(buf)
end

function M.computer_name()
    return read_sized_string(function(buf, size) return kernel32.GetComputerNameW(buf, size) end, 256)
end

function M.computer_name_ex(name_type)
    name_type = name_type or ComputerNameDnsFullyQualified
    return read_sized_string(function(buf, size) return kernel32.GetComputerNameExW(name_type, buf, size) end, 256)
end

function M.info()
    return {
        name = M.name(),
        sam = M.full_name(secur32.NameSamCompatible),
        upn = M.full_name(secur32.NameUserPrincipal),
        computer = M.computer_name(),
        dns_hostname = M.computer_name_ex(ComputerNameDnsHostname),
        dns_domain = M.computer_name_ex(ComputerNameDnsDomain),
        dns_fqdn = M.computer_name_ex(ComputerNameDnsFullyQualified),
        elevated = token.is_elevated(),
    }
end

return M
