local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.core.handle'
local C = require 'win-utils.core.ffi_defs'
local table_new = require 'table.new'
local table_ext = require 'ext.table'
local pnp = require 'win-utils.sys.pnp' -- [NEW] Import PNP

local M = {}

-- ... [M.list, M.open 保持不变] ...
function M.list()
    local name = ffi.new("wchar_t[261]")
    local hFind = kernel32.FindFirstVolumeW(name, 261)
    if hFind == ffi.cast("HANDLE", -1) then return nil, util.last_error("FindFirstVolume") end
    
    local res = table_new(8, 0)
    setmetatable(res, { __index = table_ext })
    
    ::continue_enum::
    
    local item = { 
        guid_path = util.from_wide(name), 
        mount_points = {} 
    }
    
    local buf = ffi.new("wchar_t[1024]")
    local len = ffi.new("DWORD[1]")
    
    if kernel32.GetVolumePathNamesForVolumeNameW(name, buf, 1024, len) ~= 0 then
        local p = buf
        while true do
            local mp = util.from_wide(p)
            if not mp or mp == "" then break end
            table.insert(item.mount_points, mp)
            while p[0] ~= 0 do p = p + 1 end
            p = p + 1
            if p >= buf + len[0] then break end
        end
    end
    
    local lab = ffi.new("wchar_t[261]")
    local fs = ffi.new("wchar_t[261]")
    if kernel32.GetVolumeInformationW(name, lab, 261, nil, nil, nil, fs, 261) ~= 0 then
        item.label = util.from_wide(lab)
        item.fs = util.from_wide(fs)
    end
    
    table.insert(res, item)
    
    if kernel32.FindNextVolumeW(hFind, name, 261) ~= 0 then
        goto continue_enum
    end
    
    kernel32.FindVolumeClose(hFind)
    return res
end

function M.open(path, write)
    local p = path
    if p:match("^%a:$") then p = "\\\\.\\" .. p
    elseif p:match("^%a:\\$") then p = "\\\\.\\" .. p:sub(1,2) 
    elseif p:sub(-1)=="\\" then p = p:sub(1,-2) end
    
    local acc = write and bit.bor(C.GENERIC_READ, C.GENERIC_WRITE) or C.GENERIC_READ
    local h = kernel32.CreateFileW(util.to_wide(p), acc, 3, nil, 3, 0, nil)
    
    if h == ffi.cast("HANDLE", -1) then 
        return nil, util.last_error("CreateFile failed") 
    end
    return Handle(h)
end

function M.find_guid_by_partition(drive_index, partition_offset)
    -- (保持原样)
    local vols = M.list()
    if not vols then return nil end
    
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 then
                if ext.Extents[0].DiskNumber == drive_index and 
                   tonumber(ext.Extents[0].StartingOffset.QuadPart) == partition_offset then
                    hVol:close()
                    return v.guid_path
                end
            end
            hVol:close()
        end
    end
    return nil
end

-- [REFACTORED] 基于事件驱动的智能等待
function M.wait_for_partition(drive_index, partition_offset, timeout_ms)
    local start = kernel32.GetTickCount()
    local limit = timeout_ms or 15000
    
    -- 1. 立即检查一次 (Fast Path)
    local guid = M.find_guid_by_partition(drive_index, partition_offset)
    if guid then return guid end
    
    -- 2. 进入事件循环
    local watcher = nil
    -- 创建监听器可能失败（极其罕见），如果失败则回退到 Sleep
    pcall(function() watcher = pnp.PnpWatcher() end)
    
    while true do
        local elapsed = kernel32.GetTickCount() - start
        if elapsed > limit then 
            if watcher then watcher:close() end
            return nil, "Timeout waiting for volume arrival" 
        end
        
        -- 如果监听器创建成功，使用事件等待
        if watcher then
            local remaining = limit - elapsed
            -- 等待事件，或者剩余时间耗尽
            watcher:wait(math.min(2000, remaining)) -- 每 2s 强制检查一次，防止信号丢失
        else
            -- 降级方案
            kernel32.Sleep(500)
        end
        
        -- 3. 再次检查
        guid = M.find_guid_by_partition(drive_index, partition_offset)
        if guid then 
            if watcher then watcher:close() end
            return guid 
        end
    end
end

function M.find_free_letter()
    -- (保持原样)
    local mask = kernel32.GetLogicalDrives()
    for i = 25, 2, -1 do 
        if bit.band(mask, bit.lshift(1, i)) == 0 then 
            return string.char(65 + i) .. ":\\" 
        end
    end
    return nil
end

function M.assign(idx, offset, letter)
    -- 1. 等待卷出现 (Event Driven)
    local guid_path, err = M.wait_for_partition(idx, offset, 15000)
    if not guid_path then return false, "Volume not found: " .. tostring(err) end
    
    local mount_point = letter or M.find_free_letter()
    if not mount_point then return false, "No free letters" end
    
    if mount_point:sub(-1) ~= "\\" then mount_point = mount_point .. "\\" end
    if guid_path:sub(-1) ~= "\\" then guid_path = guid_path .. "\\" end
    
    -- [REMOVED] 这里不再需要死板的 Sleep(1000)，因为我们已经确认了卷的存在
    -- 但为了给 MountManager 一点点内部锁的时间，保留 100ms 更加稳健
    kernel32.Sleep(100)
    
    if kernel32.SetVolumeMountPointW(util.to_wide(mount_point), util.to_wide(guid_path)) == 0 then
        local msg, code = util.last_error()
        return false, string.format("SetVolumeMountPoint failed: %s (%d)", msg, code)
    end
    return true, mount_point
end

function M.unmount_all_on_disk(idx)
    -- (保持原样)
    local vols = M.list()
    if not vols then return end
    
    for _, v in ipairs(vols) do
        local hVol = M.open(v.guid_path)
        if hVol then
            local ext = util.ioctl(hVol:get(), defs.IOCTL.GET_VOL_EXTENTS, nil, 0, "VOLUME_DISK_EXTENTS")
            if ext and ext.NumberOfDiskExtents > 0 and ext.Extents[0].DiskNumber == idx then
                for _, mp in ipairs(v.mount_points) do 
                    kernel32.DeleteVolumeMountPointW(util.to_wide(mp)) 
                end
                util.ioctl(hVol:get(), defs.IOCTL.DISMOUNT)
            end
            hVol:close()
        end
    end
end

function M.set_label(path, label)
    -- (保持原样)
    local root = path
    if #root == 2 and root:sub(2,2) == ":" then root = root .. "\\"
    elseif root:sub(-1) ~= "\\" then root = root .. "\\" end
    
    if kernel32.SetVolumeLabelW(util.to_wide(root), util.to_wide(label)) == 0 then
        return false, util.last_error("SetVolumeLabel failed")
    end
    return true
end

return M