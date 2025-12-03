local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local class = require 'win-utils.deps'.class
local Handle = require 'win-utils.handle'

local Job = class()

function Job:init(name)
    local h = kernel32.CreateJobObjectW(nil, name and util.to_wide(name) or nil)
    if h == nil then error("CreateJobObject failed: " .. util.format_error()) end
    self.obj = Handle.new(h)
end

function Job:set_kill_on_close()
    local info = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    info.BasicLimitInformation.LimitFlags = 0x00002000 -- KILL_ON_JOB_CLOSE
    return kernel32.SetInformationJobObject(self.obj:get(), 9, info, ffi.sizeof(info)) ~= 0
end

function Job:assign(hProcess)
    return kernel32.AssignProcessToJobObject(self.obj:get(), hProcess) ~= 0
end

function Job:close()
    self.obj:close()
end

local M = {}
function M.create(name) return Job(name) end
return M