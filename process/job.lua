local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'

local M = {}
local Job = {}
Job.__index = Job

-- 创建作业对象
function M.create(name)
    local wname = name and util.to_wide(name) or nil
    local hJob = kernel32.CreateJobObjectW(nil, wname)
    if hJob == nil then return nil, util.format_error() end
    return setmetatable({ handle = Handle.guard(hJob) }, Job)
end

-- [核心功能] 开启 "Kill on Close"
-- 当 Job 句柄关闭（或宿主进程结束）时，Job 内的所有子进程会被系统强制杀死
function Job:set_kill_on_close()
    local info = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    info.BasicLimitInformation.LimitFlags = 0x00002000 -- JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    
    local res = kernel32.SetInformationJobObject(
        self.handle,
        9, -- JobObjectExtendedLimitInformation
        info,
        ffi.sizeof(info)
    )
    return res ~= 0
end

-- 将进程加入 Job
function Job:assign(process_handle)
    if kernel32.AssignProcessToJobObject(self.handle, process_handle) == 0 then
        return false, util.format_error()
    end
    return true
end

function Job:close()
    if self.handle then
        Handle.close(self.handle)
        self.handle = nil
    end
end

return M