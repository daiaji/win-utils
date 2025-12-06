local ffi = require 'ffi'
local bit = require 'bit'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local defs = require 'win-utils.disk.defs'
local Handle = require 'win-utils.core.handle'
local C = require 'win-utils.core.ffi_defs'
local table_new = require 'table.new'
local table_ext = require 'ext.table'
local pnp = require 'win-utils.sys.pnp'

local M = {}

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

-- 智能等待分区就绪
function M.wait_for_partition(drive_index, partition_offset, timeout_ms)
    local start = kernel32.GetTickCount()
    local limit = timeout_ms or 15000
    
    local guid = M.find_guid_by_partition(drive_index, partition_offset)
    if guid then return guid end
    
    local watcher = nil
    pcall(function() watcher = pnp.PnpWatcher() end)
    
    while true do
        local elapsed = kernel32.GetTickCount() - start
        if elapsed > limit then 
            if watcher then watcher:close() end
            return nil, "Timeout waiting for volume arrival" 
        end
        
        if watcher then
            local remaining = limit - elapsed
            watcher:wait(math.min(2000, remaining))
        else
            kernel32.Sleep(500)
        end
        
        guid = M.find_guid_by_partition(drive_index, partition_offset)
        if guid then 
            if watcher then watcher:close() end
            return guid 
        end
    end
end

-- [Helper] 获取排除指定列表后的第一个空闲盘符
function M.find_free_letter(exclude_map)
    local mask = kernel32.GetLogicalDrives()
    exclude_map = exclude_map or {}
    for i = 25, 2, -1 do 
        local letter_char = string.char(65 + i)
        local letter = letter_char .. ":\\"
        if bit.band(mask, bit.lshift(1, i)) == 0 and not exclude_map[letter_char] then
            return letter
        end
    end
    return nil
end

function M.assign(idx, offset, letter)
    -- 1. 等待卷出现
    local guid_path, err = M.wait_for_partition(idx, offset, 15000)
    if not guid_path then return false, "Volume not found: " .. tostring(err) end
    
    local exclude_map = {}
    local attempt = 0
    local max_attempts = letter and 1 or 5 -- 如果指定了盘符，只试1次；否则试5次不同盘符
    
    while attempt < max_attempts do
        attempt = attempt + 1
        
        -- 2. 选定盘符
        local mount_point = letter or M.find_free_letter(exclude_map)
        if not mount_point then return false, "No free letters" end
        
        if mount_point:sub(-1) ~= "\\" then mount_point = mount_point .. "\\" end
        if guid_path:sub(-1) ~= "\\" then guid_path = guid_path .. "\\" end
        
        -- [FIX] 防御性清理：确保没有残留的 DOS 设备映射
        -- 如果之前 format 使用了 temp_mount(Z:) 且未干净卸载，这里会帮忙清理
        local raw_letter = mount_point:sub(1, 2)
        kernel32.DefineDosDeviceW(2, util.to_wide(raw_letter), nil) -- DDD_REMOVE_DEFINITION
        
        -- 3. 尝试挂载 (带重试)
        local w_mount = util.to_wide(mount_point)
        local w_guid = util.to_wide(guid_path)
        local success = false
        local last_code = 0
        local last_msg = ""
        
        for r = 1, 5 do
            if kernel32.SetVolumeMountPointW(w_mount, w_guid) ~= 0 then
                success = true
                break
            end
            
            last_msg, last_code = util.last_error()
            
            -- 如果是 87 (参数错误)，可能是盘符被占用或状态未刷新，尝试稍等
            if last_code == 87 then
                kernel32.Sleep(200)
            else
                -- 其他错误（如权限不足）可能无法通过重试解决
                break
            end
        end
        
        if success then 
            return true, mount_point 
        end
        
        -- 如果失败且是自动分配模式，记录该盘符有问题，下次循环换一个
        if not letter then
            exclude_map[mount_point:sub(1,1)] = true
            -- 继续下一次 while 循环
        else
            return false, string.format("SetVolumeMountPoint(%s) failed: %s (%d)", mount_point, last_msg, last_code)
        end
    end
    
    return false, "Failed to assign drive letter after multiple attempts"
end

function M.unmount_all_on_disk(idx)
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
    local root = path
    if #root == 2 and root:sub(2,2) == ":" then root = root .. "\\"
    elseif root:sub(-1) ~= "\\" then root = root .. "\\" end
    
    if kernel32.SetVolumeLabelW(util.to_wide(root), util.to_wide(label)) == 0 then
        return false, util.last_error("SetVolumeLabel failed")
    end
    return true
end

return M