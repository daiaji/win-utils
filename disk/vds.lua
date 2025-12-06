local ffi = require 'ffi'
local bit = require 'bit'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local vds_sdk = require 'ffi.req' 'Windows.sdk.vds'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'
local class = require 'win-utils.deps'.class
local volume_lib = require 'win-utils.disk.volume'

local M = {}
local function release(o) if o and o ~= ffi.NULL then o.lpVtbl.Release(o) end end

local VdsContext = class()

function VdsContext:init()
    ole32.CoInitializeEx(nil, 0)
    local ld = ffi.new("void*[1]")
    local hr = ole32.CoCreateInstance(vds_sdk.CLSID_VdsLoader, nil, 0x17, vds_sdk.IID_IVdsServiceLoader, ld)
    
    if hr >= 0 then
        self.loader = ffi.cast("IVdsServiceLoader*", ld[0])
        local svc = ffi.new("IVdsService*[1]")
        if self.loader.lpVtbl.LoadService(self.loader, nil, svc) >= 0 then
            self.service = svc[0]
            self.service.lpVtbl.WaitForServiceReady(self.service)
        end
    else
        self.err = string.format("CoCreateInstance failed: 0x%X", hr)
    end
end

function VdsContext:close()
    if self.service then release(self.service); self.service = nil end
    if self.loader then release(self.loader); self.loader = nil end
    ole32.CoUninitialize()
end

function VdsContext:get_disk(idx)
    if not self.service then return nil end
    local target = util.to_wide(string.format("\\\\?\\PhysicalDrive%d", idx))
    local enum = ffi.new("IEnumVdsObject*[1]")
    if self.service.lpVtbl.QueryProviders(self.service, 1, enum) < 0 then return nil end
    
    local found = nil
    local unk = ffi.new("IUnknown*[1]")
    local n = ffi.new("ULONG[1]")
    
    while not found and enum[0].lpVtbl.Next(enum[0], 1, unk, n) == 0 and n[0] > 0 do
        local prov = ffi.new("IVdsProvider*[1]")
        if unk[0].lpVtbl.QueryInterface(unk[0], vds_sdk.IID_IVdsProvider, ffi.cast("void**", prov)) == 0 then
            local sw = ffi.new("IVdsSwProvider*[1]")
            if prov[0].lpVtbl.QueryInterface(prov[0], vds_sdk.IID_IVdsSwProvider, ffi.cast("void**", sw)) == 0 then
                local packs = ffi.new("IEnumVdsObject*[1]")
                if sw[0].lpVtbl.QueryPacks(sw[0], packs) == 0 then
                    while not found and packs[0].lpVtbl.Next(packs[0], 1, unk, n) == 0 and n[0] > 0 do
                        local pack = ffi.new("IVdsPack*[1]")
                        if unk[0].lpVtbl.QueryInterface(unk[0], vds_sdk.IID_IVdsPack, ffi.cast("void**", pack)) == 0 then
                            local disks = ffi.new("IEnumVdsObject*[1]")
                            if pack[0].lpVtbl.QueryDisks(pack[0], disks) == 0 then
                                while not found and disks[0].lpVtbl.Next(disks[0], 1, unk, n) == 0 and n[0] > 0 do
                                    local d = ffi.new("IVdsDisk*[1]")
                                    if unk[0].lpVtbl.QueryInterface(unk[0], vds_sdk.IID_IVdsDisk, ffi.cast("void**", d)) == 0 then
                                        local prop = ffi.new("VDS_DISK_PROP")
                                        if d[0].lpVtbl.GetProperties(d[0], prop) == 0 then
                                            if kernel32.lstrcmpiW(target, prop.pwszName) == 0 then
                                                d[0].lpVtbl.AddRef(d[0]); found = d[0]
                                            end
                                            ole32.CoTaskMemFree(prop.pwszName); ole32.CoTaskMemFree(prop.pwszAdaptorName)
                                            ole32.CoTaskMemFree(prop.pwszDevicePath); ole32.CoTaskMemFree(prop.pwszFriendlyName)
                                        end
                                        release(d[0])
                                    end
                                    release(unk[0])
                                end
                                release(disks[0])
                            end
                            release(pack[0])
                        end
                        release(unk[0])
                    end
                    release(packs[0])
                end
                release(sw[0])
            end
            release(prov[0])
        end
        release(unk[0])
    end
    release(enum[0])
    return found
end

local function vds_op(idx, cb)
    local ctx = VdsContext()
    if not ctx.service then 
        local err = ctx.err or "Service load failed"
        ctx:close()
        return false, err 
    end
    
    local disk = ctx:get_disk(idx)
    if not disk then ctx:close(); return false, "Disk not found" end
    
    local adv = ffi.new("IVdsAdvancedDisk*[1]")
    local ok, msg = false, "IVdsAdvancedDisk interface not found"
    
    if disk.lpVtbl.QueryInterface(disk, vds_sdk.IID_IVdsAdvancedDisk, ffi.cast("void**", adv)) == 0 then
        ok, msg = cb(adv[0])
        release(adv[0])
    end
    release(disk); ctx:close()
    return ok, msg
end

function M.clean(idx)
    return vds_op(idx, function(adv)
        local async = ffi.new("IVdsAsync*[1]")
        if adv.lpVtbl.Clean(adv, 1, 1, 0, async) ~= 0 then return false, "Clean call failed" end
        local hr, out = ffi.new("HRESULT[1]"), ffi.new("VDS_ASYNC_OUTPUT")
        async[0].lpVtbl.Wait(async[0], hr, out)
        release(async[0])
        return (hr[0] >= 0), string.format("0x%X", hr[0])
    end)
end

function M.create_partition(idx, offset, size, params)
    return vds_op(idx, function(adv)
        local p = ffi.new("CREATE_PARTITION_PARAMETERS")
        if params.style == "MBR" then
            p.style = 1 
            p.Info.Mbr.PartitionType = params.type or 0x07
            p.Info.Mbr.BootIndicator = params.active and 1 or 0
        else
            p.style = 2 
            p.Info.Gpt.PartitionType = util.guid_from_str(params.type or "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}")
            if params.id then p.Info.Gpt.PartitionId = util.guid_from_str(params.id) end
            p.Info.Gpt.Attributes = params.attributes or 0
            if params.name then 
                local w = util.to_wide(params.name)
                ffi.copy(p.Info.Gpt.Name, w, math.min(72, ffi.sizeof(w)))
            end
        end
        
        local async = ffi.new("IVdsAsync*[1]")
        if adv.lpVtbl.CreatePartition(adv, offset, size, p, async) ~= 0 then return false, "CreatePartition call failed" end
        local hr, out = ffi.new("HRESULT[1]"), ffi.new("VDS_ASYNC_OUTPUT")
        async[0].lpVtbl.Wait(async[0], hr, out)
        release(async[0])
        return (hr[0] >= 0), string.format("0x%X", hr[0])
    end)
end

function M.format(idx, offset, fs, label, quick, cluster, rev)
    local guid = volume_lib.find_guid_by_partition(idx, offset)
    if not guid then return false, "Volume GUID not found for partition" end
    local wguid = util.to_wide(guid:sub(-1)=="\\" and guid or guid.."\\")
    
    local ctx = VdsContext()
    if not ctx.service then 
        local err = ctx.err or "Init failed"
        ctx:close()
        return false, err 
    end
    
    local disk = ctx:get_disk(idx)
    if not disk then ctx:close(); return false, "Disk object not found" end
    
    local pack = ffi.new("IVdsPack*[1]")
    local ok, msg = false, "Volume not found in VDS"
    
    if disk.lpVtbl.GetPack(disk, pack) == 0 then
        local enum = ffi.new("IEnumVdsObject*[1]")
        if pack[0].lpVtbl.QueryVolumes(pack[0], enum) == 0 then
            local unk = ffi.new("IUnknown*[1]"); local n = ffi.new("ULONG[1]")
            while not ok and enum[0].lpVtbl.Next(enum[0], 1, unk, n) == 0 and n[0] > 0 do
                local vol = ffi.new("IVdsVolume*[1]")
                if unk[0].lpVtbl.QueryInterface(unk[0], vds_sdk.IID_IVdsVolume, ffi.cast("void**", vol)) == 0 then
                    local mf3 = ffi.new("IVdsVolumeMF3*[1]")
                    if vol[0].lpVtbl.QueryInterface(vol[0], vds_sdk.IID_IVdsVolumeMF3, ffi.cast("void**", mf3)) == 0 then
                        local paths = ffi.new("LPWSTR*[1]"); local np = ffi.new("ULONG[1]")
                        if mf3[0].lpVtbl.QueryVolumeGuidPathnames(mf3[0], paths, np) == 0 then
                            for i=0, np[0]-1 do
                                if kernel32.lstrcmpiW(paths[0][i], wguid) == 0 then
                                    local async = ffi.new("IVdsAsync*[1]")
                                    if mf3[0].lpVtbl.FormatEx2(mf3[0], util.to_wide(fs), rev or 0, cluster or 0, util.to_wide(label), quick and 1 or 0, async) == 0 then
                                        local hr = ffi.new("HRESULT[1]"); local out = ffi.new("VDS_ASYNC_OUTPUT")
                                        async[0].lpVtbl.Wait(async[0], hr, out)
                                        release(async[0])
                                        ok = (hr[0] >= 0); msg = ok and "Success" or string.format("0x%X", hr[0])
                                    else
                                        msg = "FormatEx2 call failed"
                                    end
                                end
                                ole32.CoTaskMemFree(paths[0][i])
                            end
                            ole32.CoTaskMemFree(paths[0])
                        end
                        release(mf3[0])
                    end
                    release(vol[0])
                end
                release(unk[0])
            end
            release(enum[0])
        end
        release(pack[0])
    end
    
    release(disk); ctx:close()
    return ok, msg
end

return M