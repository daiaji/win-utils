local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local vds_sdk = require 'ffi.req' 'Windows.sdk.vds'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local volume_lib = require 'win-utils.disk.volume'

local M = {}
local C = ffi.C

local function release(obj)
    if obj ~= nil and obj ~= ffi.NULL then
        obj.lpVtbl.Release(obj)
    end
end

local function init_com()
    local flags = bit.bor(ole32.C.COINIT_APARTMENTTHREADED, ole32.C.COINIT_DISABLE_OLE1DDE)
    local hr = ole32.CoInitializeEx(nil, flags)
    return hr >= 0
end

local function uninit_com()
    ole32.CoUninitialize()
end

local VdsContext = {}
VdsContext.__index = VdsContext

function M.create_context()
    if not init_com() then return nil, "CoInitializeEx failed" end
    
    local ctx = setmetatable({
        loader = nil,
        service = nil
    }, VdsContext)
    
    local ppLoader = ffi.new("void*[1]")
    local ctx_flags = bit.bor(ole32.C.CLSCTX_LOCAL_SERVER, ole32.C.CLSCTX_REMOTE_SERVER)
    
    local hr = ole32.CoCreateInstance(vds_sdk.CLSID_VdsLoader, nil, 
        ctx_flags, 
        vds_sdk.IID_IVdsServiceLoader, ppLoader)
        
    if hr < 0 then 
        uninit_com()
        return nil, "CoCreateInstance(VdsLoader) failed" 
    end
    ctx.loader = ffi.cast("IVdsServiceLoader*", ppLoader[0])
    
    local ppService = ffi.new("IVdsService*[1]")
    hr = ctx.loader.lpVtbl.LoadService(ctx.loader, nil, ppService)
    if hr < 0 then 
        ctx:close()
        return nil, "LoadService failed" 
    end
    ctx.service = ppService[0]
    
    hr = ctx.service.lpVtbl.WaitForServiceReady(ctx.service)
    if hr < 0 then
        ctx:close()
        return nil, "VDS Service not ready"
    end
    
    return ctx
end

function VdsContext:close()
    if self.service then release(self.service); self.service = nil end
    if self.loader then release(self.loader); self.loader = nil end
    uninit_com()
end

function VdsContext:get_disk(drive_index)
    local target_path = string.format("\\\\?\\PhysicalDrive%d", drive_index)
    local w_target_path = util.to_wide(target_path)
    
    local enum_ptr = ffi.new("IEnumVdsObject*[1]")
    local hr = self.service.lpVtbl.QueryProviders(self.service, vds_sdk.C.VDS_QUERY_SOFTWARE_PROVIDERS, enum_ptr)
    if hr < 0 then return nil, "QueryProviders failed" end
    local enum_prov = enum_ptr[0]
    
    local found_disk = nil
    local unk_ptr = ffi.new("IUnknown*[1]")
    local fetched = ffi.new("ULONG[1]")
    
    while enum_prov.lpVtbl.Next(enum_prov, 1, unk_ptr, fetched) == 0 and fetched[0] > 0 do
        local unk = unk_ptr[0]
        local prov_ptr = ffi.new("IVdsProvider*[1]")
        
        if unk.lpVtbl.QueryInterface(unk, vds_sdk.IID_IVdsProvider, ffi.cast("void**", prov_ptr)) == 0 then
            local prov = prov_ptr[0]
            local sw_prov_ptr = ffi.new("IVdsSwProvider*[1]")
            
            if prov.lpVtbl.QueryInterface(prov, vds_sdk.IID_IVdsSwProvider, ffi.cast("void**", sw_prov_ptr)) == 0 then
                local sw_prov = sw_prov_ptr[0]
                local enum_pack_ptr = ffi.new("IEnumVdsObject*[1]")
                
                if sw_prov.lpVtbl.QueryPacks(sw_prov, enum_pack_ptr) == 0 then
                    local enum_pack = enum_pack_ptr[0]
                    
                    while found_disk == nil and enum_pack.lpVtbl.Next(enum_pack, 1, unk_ptr, fetched) == 0 and fetched[0] > 0 do
                        local pack_unk = unk_ptr[0]
                        local pack_ptr = ffi.new("IVdsPack*[1]")
                        
                        if pack_unk.lpVtbl.QueryInterface(pack_unk, vds_sdk.IID_IVdsPack, ffi.cast("void**", pack_ptr)) == 0 then
                            local pack = pack_ptr[0]
                            local enum_disk_ptr = ffi.new("IEnumVdsObject*[1]")
                            
                            if pack.lpVtbl.QueryDisks(pack, enum_disk_ptr) == 0 then
                                local enum_disk = enum_disk_ptr[0]
                                
                                while found_disk == nil and enum_disk.lpVtbl.Next(enum_disk, 1, unk_ptr, fetched) == 0 and fetched[0] > 0 do
                                    local disk_unk = unk_ptr[0]
                                    local disk_ptr = ffi.new("IVdsDisk*[1]")
                                    
                                    if disk_unk.lpVtbl.QueryInterface(disk_unk, vds_sdk.IID_IVdsDisk, ffi.cast("void**", disk_ptr)) == 0 then
                                        local disk = disk_ptr[0]
                                        local prop = ffi.new("VDS_DISK_PROP")
                                        
                                        if disk.lpVtbl.GetProperties(disk, prop) == 0 then
                                            if kernel32.lstrcmpiW(w_target_path, prop.pwszName) == 0 then
                                                disk.lpVtbl.AddRef(disk)
                                                found_disk = disk
                                            end
                                            ole32.CoTaskMemFree(prop.pwszName)
                                            ole32.CoTaskMemFree(prop.pwszAdaptorName)
                                            ole32.CoTaskMemFree(prop.pwszDevicePath)
                                            ole32.CoTaskMemFree(prop.pwszFriendlyName)
                                        end
                                        release(disk)
                                    end
                                    release(disk_unk)
                                end
                                release(enum_disk)
                            end
                            release(pack)
                        end
                        release(pack_unk)
                    end
                    release(enum_pack)
                end
                release(sw_prov)
            end
            release(prov)
        end
        release(unk)
        if found_disk then break end
    end
    release(enum_prov)
    
    return found_disk
end

function M.clean(drive_index)
    local ctx, err = M.create_context()
    if not ctx then return false, err end
    
    local disk = ctx:get_disk(drive_index)
    if not disk then 
        ctx:close()
        return false, "Disk not found in VDS"
    end
    
    local adv_disk_ptr = ffi.new("IVdsAdvancedDisk*[1]")
    local hr = disk.lpVtbl.QueryInterface(disk, vds_sdk.IID_IVdsAdvancedDisk, ffi.cast("void**", adv_disk_ptr))
    local success = false
    local msg = ""
    
    if hr >= 0 then
        local adv_disk = adv_disk_ptr[0]
        local async_ptr = ffi.new("IVdsAsync*[1]")
        
        hr = adv_disk.lpVtbl.Clean(adv_disk, 1, 1, 0, async_ptr)
        if hr >= 0 then
            local async = async_ptr[0]
            local hr_res = ffi.new("HRESULT[1]")
            local output = ffi.new("VDS_ASYNC_OUTPUT") 
            hr = async.lpVtbl.Wait(async, hr_res, output)
            if hr >= 0 and hr_res[0] >= 0 then
                success = true
            else
                msg = string.format("Async Clean failed: 0x%08X", hr_res[0])
            end
            release(async)
        else
            msg = string.format("Clean call failed: 0x%08X", hr)
        end
        release(adv_disk)
    else
        msg = "IVdsAdvancedDisk not supported"
    end
    
    release(disk)
    ctx:close()
    return success, msg
end

function M.delete_partition(drive_index, offset, force)
    local ctx, err = M.create_context()
    if not ctx then return false, err end
    
    local disk = ctx:get_disk(drive_index)
    if not disk then 
        ctx:close()
        return false, "Disk not found in VDS"
    end
    
    local adv_disk_ptr = ffi.new("IVdsAdvancedDisk*[1]")
    local hr = disk.lpVtbl.QueryInterface(disk, vds_sdk.IID_IVdsAdvancedDisk, ffi.cast("void**", adv_disk_ptr))
    local success = false
    local msg = ""
    
    if hr >= 0 then
        local adv_disk = adv_disk_ptr[0]
        hr = adv_disk.lpVtbl.DeletePartition(adv_disk, offset, force and 1 or 0, force and 1 or 0)
        
        if hr >= 0 then
            success = true
        else
            msg = string.format("DeletePartition failed: 0x%08X", hr)
        end
        release(adv_disk)
    else
        msg = "IVdsAdvancedDisk not supported"
    end
    
    release(disk)
    ctx:close()
    return success, msg
end

function M.create_partition(drive_index, offset, size, params)
    local ctx, err = M.create_context()
    if not ctx then return false, err end
    
    local disk = ctx:get_disk(drive_index)
    if not disk then 
        ctx:close()
        return false, "Disk not found in VDS" 
    end
    
    local adv_disk_ptr = ffi.new("IVdsAdvancedDisk*[1]")
    local hr = disk.lpVtbl.QueryInterface(disk, vds_sdk.IID_IVdsAdvancedDisk, ffi.cast("void**", adv_disk_ptr))
    local success = false
    local msg = ""
    
    if hr >= 0 then
        local adv_disk = adv_disk_ptr[0]
        local vds_params = ffi.new("CREATE_PARTITION_PARAMETERS")
        
        if params.style == "MBR" then
            vds_params.style = vds_sdk.C.VDS_PST_MBR
            vds_params.Info.Mbr.PartitionType = params.type or 0x07
            vds_params.Info.Mbr.BootIndicator = params.active and 1 or 0
        else
            vds_params.style = vds_sdk.C.VDS_PST_GPT
            vds_params.Info.Gpt.PartitionType = util.guid_from_str(params.type or "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}")
            if params.id then vds_params.Info.Gpt.PartitionId = util.guid_from_str(params.id) end
            if params.attributes then vds_params.Info.Gpt.Attributes = params.attributes end
            if params.name then 
                local wname = util.to_wide(params.name)
                ffi.copy(vds_params.Info.Gpt.Name, wname, math.min(72, ffi.sizeof(wname)))
            end
        end
        
        local async_ptr = ffi.new("IVdsAsync*[1]")
        hr = adv_disk.lpVtbl.CreatePartition(adv_disk, offset, size, vds_params, async_ptr)
        
        if hr >= 0 then
            local async = async_ptr[0]
            local hr_res = ffi.new("HRESULT[1]")
            local output = ffi.new("VDS_ASYNC_OUTPUT") 
            hr = async.lpVtbl.Wait(async, hr_res, output)
            if hr >= 0 and hr_res[0] >= 0 then
                success = true
                msg = "Partition created"
            else
                msg = string.format("Async CreatePartition failed: 0x%08X", hr_res[0])
            end
            release(async)
        else
            msg = string.format("CreatePartition call failed: 0x%08X", hr)
        end
        release(adv_disk)
    else
        msg = "IVdsAdvancedDisk not supported"
    end
    
    release(disk)
    ctx:close()
    return success, msg
end

-- [ENHANCED] Added fs_revision parameter
-- fs_revision: Hex number (e.g. 0x201 for UDF 2.01). 0 = Default.
function M.format(drive_index, partition_offset, fs_name, label, quick, cluster_size, fs_revision)
    local target_guid_path = volume_lib.find_guid_by_partition(drive_index, partition_offset)
    if not target_guid_path then 
        return false, "Partition not found or volume not mounted (Check drive index and offset)" 
    end
    
    if target_guid_path:sub(-1) ~= "\\" then target_guid_path = target_guid_path .. "\\" end
    local w_target_guid = util.to_wide(target_guid_path)

    local ctx, err = M.create_context()
    if not ctx then return false, err end
    
    local disk = ctx:get_disk(drive_index)
    if not disk then 
        ctx:close()
        return false, "Disk not found in VDS" 
    end
    
    local pack_ptr = ffi.new("IVdsPack*[1]")
    local hr = disk.lpVtbl.GetPack(disk, pack_ptr)
    local success = false
    local msg = "Volume not found in VDS Pack"
    
    if hr >= 0 then
        local pack = pack_ptr[0]
        local enum_vol_ptr = ffi.new("IEnumVdsObject*[1]")
        
        if pack.lpVtbl.QueryVolumes(pack, enum_vol_ptr) == 0 then
            local enum_vol = enum_vol_ptr[0]
            local unk_ptr = ffi.new("IUnknown*[1]")
            local fetched = ffi.new("ULONG[1]")
            
            while not success and enum_vol.lpVtbl.Next(enum_vol, 1, unk_ptr, fetched) == 0 and fetched[0] > 0 do
                local vol_unk = unk_ptr[0]
                local vol_ptr = ffi.new("IVdsVolume*[1]")
                
                if vol_unk.lpVtbl.QueryInterface(vol_unk, vds_sdk.IID_IVdsVolume, ffi.cast("void**", vol_ptr)) == 0 then
                    local vol = vol_ptr[0]
                    local mf3_ptr = ffi.new("IVdsVolumeMF3*[1]")
                    
                    if vol.lpVtbl.QueryInterface(vol, vds_sdk.IID_IVdsVolumeMF3, ffi.cast("void**", mf3_ptr)) == 0 then
                        local mf3 = mf3_ptr[0]
                        
                        local paths_ptr = ffi.new("LPWSTR*[1]")
                        local num_paths_ptr = ffi.new("ULONG[1]")
                        
                        if mf3.lpVtbl.QueryVolumeGuidPathnames(mf3, paths_ptr, num_paths_ptr) == 0 then
                            local num_paths = num_paths_ptr[0]
                            local paths = paths_ptr[0]
                            local is_match = false
                            
                            for i = 0, num_paths - 1 do
                                local path = paths[i] -- LPWSTR
                                if kernel32.lstrcmpiW(path, w_target_guid) == 0 then
                                    is_match = true
                                end
                                ole32.CoTaskMemFree(path)
                            end
                            ole32.CoTaskMemFree(paths)
                            
                            if is_match then
                                local w_fs = util.to_wide(fs_name)
                                local w_label = util.to_wide(label)
                                local async_ptr = ffi.new("IVdsAsync*[1]")
                                local options = quick and 1 or 0 
                                
                                -- [FIX] Pass fs_revision correctly
                                hr = mf3.lpVtbl.FormatEx2(mf3, w_fs, fs_revision or 0, cluster_size or 0, w_label, options, async_ptr)
                                
                                if hr >= 0 then
                                    local async = async_ptr[0]
                                    local hr_res = ffi.new("HRESULT[1]")
                                    local output = ffi.new("VDS_ASYNC_OUTPUT")
                                    async.lpVtbl.Wait(async, hr_res, output)
                                    if hr_res[0] >= 0 then
                                        success = true
                                        msg = "Success"
                                    else
                                        msg = string.format("VDS Format Failed: 0x%08X", hr_res[0])
                                    end
                                    release(async)
                                else
                                    msg = string.format("FormatEx2 call failed: 0x%08X", hr)
                                end
                            end
                        end
                        release(mf3)
                    end
                    release(vol)
                end
                release(vol_unk)
            end
            release(enum_vol)
        end
        release(pack)
    end
    
    release(disk)
    ctx:close()
    return success, msg
end

return M