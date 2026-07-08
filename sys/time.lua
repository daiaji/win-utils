local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

local function systemtime_to_table(st)
    return {
        year = tonumber(st.wYear),
        month = tonumber(st.wMonth),
        day_of_week = tonumber(st.wDayOfWeek),
        day = tonumber(st.wDay),
        hour = tonumber(st.wHour),
        min = tonumber(st.wMinute),
        sec = tonumber(st.wSecond),
        msec = tonumber(st.wMilliseconds),
    }
end

local function table_to_systemtime(t)
    if type(t) ~= "table" then return nil, "time table required" end
    local st = ffi.new("SYSTEMTIME")
    st.wYear = tonumber(t.year)
    st.wMonth = tonumber(t.month)
    st.wDay = tonumber(t.day)
    if st.wYear == 0 or st.wMonth == 0 or st.wDay == 0 then
        return nil, "year, month and day required"
    end
    st.wHour = tonumber(t.hour or 0)
    st.wMinute = tonumber(t.min or t.minute or 0)
    st.wSecond = tonumber(t.sec or t.second or 0)
    st.wMilliseconds = tonumber(t.msec or t.millisecond or 0)
    return st
end

local function run_tzutil(args, opts)
    opts = opts or {}
    if opts.dry_run then return { ok = true, dry_run = true, command = "tzutil.exe " .. table.concat(args, " ") } end

    local proc = require 'win-utils.process.init'
    local result, err = proc.exec({
        file = "tzutil.exe",
        args = args,
        show = 0,
        capture_stdout = true,
        capture_stderr = true,
        timeout = opts.timeout or 10000,
    })
    if not result then return nil, err end
    if result.exit_code ~= 0 then
        return nil, result.stderr ~= "" and result.stderr or result.stdout
    end
    return result
end

function M.now()
    return os.time()
end

function M.date(format, time)
    return os.date(format or "*t", time)
end

function M.local_time()
    local st = ffi.new("SYSTEMTIME")
    kernel32.GetLocalTime(st)
    return systemtime_to_table(st)
end

function M.system_time()
    local st = ffi.new("SYSTEMTIME")
    kernel32.GetSystemTime(st)
    return systemtime_to_table(st)
end

function M.set_local_time(t, opts)
    opts = opts or {}
    if opts.dry_run then return { ok = true, dry_run = true, time = t, scope = "local" } end
    local st, err = table_to_systemtime(t)
    if not st then return false, err end
    if kernel32.SetLocalTime(st) == 0 then return false, util.last_error("SetLocalTime failed") end
    return true
end

function M.set_system_time(t, opts)
    opts = opts or {}
    if opts.dry_run then return { ok = true, dry_run = true, time = t, scope = "system" } end
    local st, err = table_to_systemtime(t)
    if not st then return false, err end
    if kernel32.SetSystemTime(st) == 0 then return false, util.last_error("SetSystemTime failed") end
    return true
end

function M.sync_ntp(server, opts)
    local ntp = require 'win-utils.net.ntp'
    return ntp.sync(server, opts)
end

function M.get_timezone(opts)
    local result, err = run_tzutil({ "/g" }, opts)
    if not result then return nil, err end
    if result.dry_run then return result end
    return (result.stdout or ""):gsub("%s+$", "")
end

function M.list_timezones(opts)
    local result, err = run_tzutil({ "/l" }, opts)
    if not result then return nil, err end
    if result.dry_run then return result end
    local zones = {}
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        if line ~= "" then zones[#zones + 1] = line end
    end
    return zones
end

function M.set_timezone(name, opts)
    if not name or name == "" then return nil, "timezone name required" end
    return run_tzutil({ "/s", name }, opts)
end

return M
