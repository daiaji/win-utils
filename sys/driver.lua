local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local newdev = require 'ffi.req' 'Windows.sdk.newdev'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local util = require 'win-utils.core.util'
local M = {}

function M.load(path)
    token.enable_privilege("SeLoadDriverPrivilege")
    local oa, a = native.init_object_attributes("\\Registry\\Machine\\System\\CurrentControlSet\\Services\\"..path)
    local r = ntdll.NtLoadDriver(oa)
    local _ = a
    return r >= 0
end

function M.unload(path)
    token.enable_privilege("SeLoadDriverPrivilege")
    local oa, a = native.init_object_attributes("\\Registry\\Machine\\System\\CurrentControlSet\\Services\\"..path)
    local r = ntdll.NtUnloadDriver(oa)
    local _ = a
    return r >= 0
end

function M.install(inf)
    local rb = ffi.new("BOOL[1]")
    return newdev.DiInstallDriverW(nil, util.to_wide(inf), 0, rb) ~= 0
end

function M.update_device(hwid, inf, force)
    local rb = ffi.new("BOOL[1]")
    return newdev.UpdateDriverForPlugAndPlayDevicesW(nil, util.to_wide(hwid), util.to_wide(inf), force and 1 or 0, rb) ~= 0
end

function M.add_to_store(inf)
    return setupapi.SetupCopyOEMInfW(util.to_wide(inf), nil, 1, 0, nil, 0, nil, nil) ~= 0
end

return M