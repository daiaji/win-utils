local ffi = require 'ffi'
local bit = require 'bit'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local token = require 'win-utils.process.token'
local native = require 'win-utils.native'

local M = {}
local C = ffi.C

local function do_power(action, flags)
    token.enable_privilege("SeShutdownPrivilege")
    return ntdll.NtInitiatePowerAction(action, 2, flags or 1, false) >= 0 -- Sleeping1=2
end

function M.shutdown(force) return do_power(C.PowerActionShutdown, force and 0x80000001 or 1) end
function M.reboot(force) return do_power(C.PowerActionShutdownReset, force and 0x80000001 or 1) end
function M.suspend() return do_power(C.PowerActionSleep, 1) end
function M.hibernate() return do_power(C.PowerActionHibernate, 1) end

function M.fast_shutdown() token.enable_privilege("SeShutdownPrivilege"); return ntdll.NtShutdownSystem(2) >= 0 end -- PowerOff
function M.fast_reboot() token.enable_privilege("SeShutdownPrivilege"); return ntdll.NtShutdownSystem(1) >= 0 end -- Reboot

function M.boot_to_firmware()
    if not token.enable_privilege("SeSystemEnvironmentPrivilege") then return false end
    local guid = ffi.new("GUID", {0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}})
    local name, a = native.to_unicode_string("OsIndications")
    local buf = ffi.new("uint64_t[1]")
    local attr = ffi.new("ULONG[1]")
    
    if ntdll.NtQuerySystemEnvironmentValueEx(name, guid, buf, ffi.new("ULONG[1]", 8), attr) < 0 then
        buf[0] = 0; attr[0] = 7 -- NV+BS+RT
    end
    
    buf[0] = buf[0] + 1 -- Bit 0: BootToFwUI
    local res = ntdll.NtSetSystemEnvironmentValueEx(name, guid, buf, 8, attr[0]) >= 0
    local _ = a
    return res
end

return M