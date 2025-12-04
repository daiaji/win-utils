local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local class = require 'win-utils.deps'.class

local Job = class()
function Job:init(name)
    local h = kernel32.CreateJobObjectW(nil, name and util.to_wide(name) or nil)
    if not h then error("CreateJob failed") end
    self.obj = Handle(h)
end
function Job:assign(proc_handle) return kernel32.AssignProcessToJobObject(self.obj:get(), proc_handle) ~= 0 end
function Job:terminate(code) return kernel32.TerminateJobObject(self.obj:get(), code) ~= 0 end
function Job:set_kill_on_close()
    local info = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    info.BasicLimitInformation.LimitFlags = 0x2000
    return kernel32.SetInformationJobObject(self.obj:get(), 9, info, ffi.sizeof(info)) ~= 0
end

local M = {}
function M.create(name) return Job(name) end
return M