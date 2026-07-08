local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local reg = require 'win-utils.reg.init'
local native = require 'win-utils.core.native'

local M = {}

local function add_block(blockers, code, message)
    table.insert(blockers, { code = code, message = message })
end

local function has_blocker(blockers)
    return #blockers > 0
end

local function volume_is_on_disk(volume_mod, guid_path, drive_idx)
    local hVol = volume_mod.open(guid_path)
    if not hVol then return false end
    local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    hVol:close()
    if not ext then return false end
    for i = 0, ext.NumberOfDiskExtents - 1 do
        if ext.Extents[i].DiskNumber == drive_idx then return true end
    end
    return false
end

local function file_exists(path)
    local attr = kernel32.GetFileAttributesW(util.to_wide(path))
    return attr ~= 0xFFFFFFFF
end

-- 检查驱动器是否包含当前运行的 Windows
function M.is_system_drive(drive_idx)
    local buf = ffi.new("wchar_t[260]")
    if kernel32.GetWindowsDirectoryW(buf, 260) == 0 then return nil, util.last_error() end
    
    -- 获取 C:
    local letter = util.from_wide(buf):sub(1, 2)
    local h = native.open_file("\\\\.\\" .. letter, "r", true)
    if not h then return nil, "Failed to open system drive handle" end
    
    local ext, err = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
    h:close()
    
    if ext then
        for i = 0, ext.NumberOfDiskExtents - 1 do
            if ext.Extents[i].DiskNumber == drive_idx then return true end
        end
    end
    return false
end

-- 检查是否存在活跃页面文件
function M.has_pagefile(drive_idx)
    local k = reg.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management")
    if not k then return false end
    
    local files = k:read("PagingFiles")
    k:close()
    if not files then return false end
    if type(files) ~= "table" then files = {files} end
    
    for _, path in ipairs(files) do
        local letter = path:sub(1, 2)
        if letter:match("^%a:") then
            local h = native.open_file("\\\\.\\" .. letter, "r", true)
            if h then
                local ext = util.ioctl(h:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
                h:close()
                if ext then
                    for i = 0, ext.NumberOfDiskExtents - 1 do
                        if ext.Extents[i].DiskNumber == drive_idx then return true end
                    end
                end
            end
        end
    end
    return false
end

function M.has_hibernation_file(drive_idx)
    local volume = require 'win-utils.disk.volume'
    local vols = volume.list()
    if not vols then return false end

    for _, v in ipairs(vols) do
        if volume_is_on_disk(volume, v.guid_path, drive_idx) then
            for _, mp in ipairs(v.mount_points) do
                if file_exists(mp .. "hiberfil.sys") then return true end
            end
        end
    end
    return false
end

-- 检查写保护注册表策略
function M.check_write_protect_policy()
    local k = reg.open_key("HKLM", "SYSTEM\\CurrentControlSet\\Control\\StorageDevicePolicies")
    if k then
        local v = k:read("WriteProtect")
        k:close()
        return v == 1
    end
    return false
end

function M.check_destructive_target(drive_idx, opts)
    opts = opts or {}
    local blockers = {}
    local warnings = {}
    local valid_target = type(drive_idx) == "number"

    if not valid_target then
        add_block(blockers, "invalid_target", "drive_idx must be a physical disk number")
    end

    if opts.dry_run ~= true and opts.require_confirm ~= false and opts.confirm ~= true then
        add_block(blockers, "confirm_required", "destructive disk operation requires confirm = true")
    end

    if valid_target and not opts.skip_open_check then
        local physical = require 'win-utils.disk.physical'
        local ok_open, drive = pcall(physical.open, drive_idx, "r", false)
        if not ok_open or not drive then
            add_block(blockers, "open_failed", "failed to open target disk: " .. tostring(drive))
        else
            if drive.media_type == 12 and opts.allow_fixed ~= true then
                add_block(blockers, "fixed_disk", "target disk is fixed media; pass allow_fixed = true to override")
            end
            local attrs, attr_err = drive:get_attributes()
            if attrs then
                if attrs.read_only then add_block(blockers, "read_only", "target disk is read-only") end
                if attrs.offline then add_block(blockers, "offline", "target disk is offline") end
            elseif attr_err then
                table.insert(warnings, "failed to query disk attributes: " .. tostring(attr_err))
            end
            drive:close()
        end
    end

    if valid_target then
        local system, system_err = M.is_system_drive(drive_idx)
        if system == true and opts.allow_system ~= true then
            add_block(blockers, "system_disk", "target disk contains the running Windows directory")
        elseif system == nil then
            table.insert(warnings, "failed to determine system disk: " .. tostring(system_err))
        end
    end

    if valid_target and M.has_pagefile(drive_idx) and opts.allow_pagefile ~= true then
        add_block(blockers, "pagefile", "target disk contains an active pagefile")
    end

    if valid_target and M.has_hibernation_file(drive_idx) and opts.allow_hibernation ~= true then
        add_block(blockers, "hiberfil", "target disk contains hiberfil.sys")
    end

    if valid_target and M.check_write_protect_policy() then
        add_block(blockers, "write_protect_policy", "StorageDevicePolicies WriteProtect is enabled")
    end

    if valid_target and opts.check_bitlocker ~= false then
        local volume = require 'win-utils.disk.volume'
        local bitlocker = require 'win-utils.disk.bitlocker'
        local vols = volume.list()
        if vols then
            for _, v in ipairs(vols) do
                if volume_is_on_disk(volume, v.guid_path, drive_idx) then
                    local status, bl_err = bitlocker.get_status(v.guid_path)
                    if status == "Locked" and opts.allow_bitlocker ~= true then
                        add_block(blockers, "bitlocker", "target disk contains a BitLocker volume")
                        break
                    elseif not status then
                        table.insert(warnings, "failed to query BitLocker status: " .. tostring(bl_err))
                    end
                end
            end
        end
    end

    local report = {
        drive_index = drive_idx,
        dry_run = opts.dry_run == true,
        blockers = blockers,
        warnings = warnings,
    }

    if opts.dry_run == true then
        return report, nil
    end

    if has_blocker(blockers) then
        return nil, blockers[1].message, report
    end

    return report, nil
end

return M
