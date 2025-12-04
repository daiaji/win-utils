local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local token = require 'win-utils.process.token'
local M = {}
function M.shutdown() token.enable_privilege("SeShutdownPrivilege"); ntdll.NtShutdownSystem(2) end
function M.reboot() token.enable_privilege("SeShutdownPrivilege"); ntdll.NtShutdownSystem(1) end
return M