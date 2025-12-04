local ffi = require 'ffi'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local native = require 'win-utils.core.native'
local util = require 'win-utils.core.util'

local M = {}

function M.list(pid)
    local h = kernel32.OpenProcess(0x40, false, pid) -- DUP_HANDLE
    if not h then return {} end
    local buf = native.query_variable_size(ntdll.NtQueryInformationProcess, h, 51, 4096)
    if not buf then kernel32.CloseHandle(h); return {} end
    local info = ffi.cast("PROCESS_HANDLE_SNAPSHOT_INFORMATION*", buf)
    local res = {}
    for i=0, tonumber(info.NumberOfHandles)-1 do
        table.insert(res, { val = tonumber(info.Handles[i].HandleValue) })
    end
    kernel32.CloseHandle(h)
    return res
end

function M.find_lockers(path)
    local target = native.dos_path_to_nt_path(path):lower()
    local pids = {}
    local procs = require('win-utils.process.init').list()
    local name_buf = ffi.new("uint8_t[4096]")
    local cur = kernel32.GetCurrentProcess()
    
    for _, p in ipairs(procs) do
        local hProc = kernel32.OpenProcess(0x40, false, p.pid)
        if hProc then
            local handles = M.list(p.pid) -- Inefficient but correct reuse
            for _, h in ipairs(handles) do
                local dup = ffi.new("HANDLE[1]")
                if ntdll.NtDuplicateObject(hProc, ffi.cast("HANDLE", h.val), cur, dup, 0, 0, 0) == 0 then
                    if kernel32.GetFileType(dup[0]) == 1 then -- FILE
                        if ntdll.NtQueryObject(dup[0], 1, name_buf, 4096, nil) == 0 then
                            local ni = ffi.cast("OBJECT_NAME_INFORMATION*", name_buf)
                            if ni.Name.Buffer ~= nil then
                                local n = util.from_wide(ni.Name.Buffer, ni.Name.Length/2)
                                if n and n:lower():find(target, 1, true) then
                                    table.insert(pids, p.pid)
                                    kernel32.CloseHandle(dup[0])
                                    break
                                end
                            end
                        end
                    end
                    kernel32.CloseHandle(dup[0])
                end
            end
            kernel32.CloseHandle(hProc)
        end
    end
    return pids
end

function M.close_remote(pid, val)
    local h = kernel32.OpenProcess(0x40, false, pid)
    if not h then return false end
    local dup = ffi.new("HANDLE[1]")
    local r = ntdll.NtDuplicateObject(h, ffi.cast("HANDLE", val), kernel32.GetCurrentProcess(), dup, 0, 0, 1) -- DUPLICATE_CLOSE_SOURCE
    if r == 0 then kernel32.CloseHandle(dup[0]) end
    kernel32.CloseHandle(h)
    return r == 0
end

return M