local lu = require('luaunit')

TestDiskSafety = {}

local unloaded = {}

local function with_stubs(stubs, fn)
    local saved = {}
    saved['win-utils.disk.safety'] = package.loaded['win-utils.disk.safety'] or unloaded
    for name, mod in pairs(stubs) do
        saved[name] = package.loaded[name] or unloaded
        package.loaded[name] = mod
    end
    package.loaded['win-utils.disk.safety'] = nil

    local ok, err = pcall(function()
        local safety = require('win-utils.disk.safety')
        fn(safety)
    end)

    package.loaded['win-utils.disk.safety'] = nil
    for name, mod in pairs(saved) do
        if mod == unloaded then
            package.loaded[name] = nil
        else
            package.loaded[name] = mod
        end
    end

    if not ok then error(err, 0) end
end

local function make_stubs(opts)
    opts = opts or {}

    local drive = {
        index = 1,
        media_type = opts.media_type or 11,
        get_attributes = function()
            return opts.attrs or { offline = false, read_only = false }
        end,
        close = function() end,
    }

    local reg_key = {
        read = function(_, name)
            if name == "PagingFiles" then return opts.pagefiles end
            if name == "WriteProtect" then return opts.write_protect and 1 or 0 end
            return nil
        end,
        close = function() end,
    }

    local volume = {
        list = function()
            return opts.volumes or {}
        end,
        open = function(path)
            if opts.volume_open_failed then return nil end
            return {
                get = function() return path end,
                close = function() end,
            }
        end,
    }

    local kernel32 = {
        GetWindowsDirectoryW = function() return 0 end,
        GetFileAttributesW = function(path)
            if opts.hiberfil_path and tostring(path) == opts.hiberfil_path then return 0 end
            return 0xFFFFFFFF
        end,
    }

    local util = {
        to_wide = function(path) return path end,
        ioctl = function(_, _, _, _, out_type)
            if out_type == "VOLUME_DISK_EXTENTS" then
                return {
                    NumberOfDiskExtents = 1,
                    Extents = {
                        [0] = { DiskNumber = opts.extent_disk or 1 },
                    },
                }
            end
            return nil
        end,
        last_error = function(prefix) return prefix or "last error" end,
    }

    return {
        ['ffi'] = require('ffi'),
        ['ffi.req'] = function(name)
            if name == 'Windows.sdk.kernel32' then return kernel32 end
            return require('ffi.req')(name)
        end,
        ['win-utils.core.util'] = util,
        ['win-utils.disk.defs'] = { IOCTL = { GET_VOL_EXTENTS = 1 } },
        ['win-utils.reg.init'] = {
            open_key = function() return reg_key end,
        },
        ['win-utils.core.native'] = {
            open_file = function()
                return {
                    get = function() return 'volume-handle' end,
                    close = function() end,
                }
            end,
        },
        ['win-utils.disk.physical'] = {
            open = function() return drive end,
        },
        ['win-utils.disk.volume'] = volume,
        ['win-utils.disk.bitlocker'] = {
            get_status = function() return opts.bitlocker_status or "None" end,
        },
    }
end

local function blocker_codes(report)
    local codes = {}
    for _, blocker in ipairs(report.blockers) do
        codes[blocker.code] = true
    end
    return codes
end

function TestDiskSafety:test_DryRun_Does_Not_Require_Confirm()
    with_stubs(make_stubs(), function(safety)
        local report, err = safety.check_destructive_target(1, { dry_run = true })
        lu.assertNil(err)
        lu.assertTrue(report.dry_run)
        lu.assertNil(blocker_codes(report).confirm_required)
    end)
end

function TestDiskSafety:test_Confirm_Required_For_Real_Operation()
    with_stubs(make_stubs(), function(safety)
        local ok, err, report = safety.check_destructive_target(1, {})
        lu.assertNil(ok)
        lu.assertEquals(err, "destructive disk operation requires confirm = true")
        lu.assertTrue(blocker_codes(report).confirm_required)
    end)
end

function TestDiskSafety:test_Fixed_Disk_Requires_Explicit_Override()
    with_stubs(make_stubs({ media_type = 12 }), function(safety)
        local ok, _, report = safety.check_destructive_target(1, { confirm = true })
        lu.assertNil(ok)
        lu.assertTrue(blocker_codes(report).fixed_disk)
    end)
end

function TestDiskSafety:test_ReadOnly_Offline_Pagefile_Hibernation_And_BitLocker_Block()
    with_stubs(make_stubs({
        attrs = { read_only = true, offline = true },
        pagefiles = { "X:\\pagefile.sys" },
        volumes = {
            { guid_path = "volume-guid", mount_points = { "X:\\" } },
        },
        hiberfil_path = "X:\\hiberfil.sys",
        bitlocker_status = "Locked",
    }), function(safety)
        local ok, _, report = safety.check_destructive_target(1, { confirm = true })
        local codes = blocker_codes(report)
        lu.assertNil(ok)
        lu.assertTrue(codes.read_only)
        lu.assertTrue(codes.offline)
        lu.assertTrue(codes.pagefile)
        lu.assertTrue(codes.hiberfil)
        lu.assertTrue(codes.bitlocker)
    end)
end
