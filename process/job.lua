local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local Handle = require 'win-utils.core.handle'
local class = require 'win-utils.deps'.class

local Job = class()
function Job:init(name)
    local h = kernel32.CreateJobObjectW(nil, name and util.to_wide(name) or nil)
    if not h then error("CreateJobObject failed: " .. util.last_error()) end
    self.obj = Handle(h)
end

function Job:assign(proc_handle) 
    if kernel32.AssignProcessToJobObject(self.obj:get(), proc_handle) == 0 then
        return false, util.last_error("AssignProcess failed")
    end
    return true
end

function Job:terminate(code) 
    if kernel32.TerminateJobObject(self.obj:get(), code) == 0 then
        return false, util.last_error("TerminateJob failed")
    end
    return true
end

function Job:set_kill_on_close()
    local info = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    info.BasicLimitInformation.LimitFlags = 0x2000 -- KILL_ON_JOB_CLOSE
    if kernel32.SetInformationJobObject(self.obj:get(), 9, info, ffi.sizeof(info)) == 0 then
        return false, util.last_error("SetInformationJobObject failed")
    end
    return true
end

local M = {}
function M.create(name) 
    local ok, res = pcall(function() return Job(name) end)
    if not ok then return nil, res end
    return res 
end
return M