local ffi = require 'ffi'
local bit = require 'bit'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.core.util'

local M = {}

-- [API] 解析 INF 文件，提取所有支持的 Hardware IDs
-- 这是一个"智能"解析器，它会遍历 Manufacturer 节，找到对应的 Models 节，
-- 并考虑当前系统架构 (x86/x64/arm64) 的修饰符。
-- @param inf_path: INF 文件路径
-- @return: table { ["PCI\VEN_..."] = true, ... } 或 nil, err
function M.get_hwids(inf_path)
    local wpath = util.to_wide(inf_path)
    local hInf = setupapi.SetupOpenInfFileW(wpath, nil, 2, nil) -- INF_STYLE_WIN4
    if hInf == ffi.cast("void*", -1) then 
        return nil, util.last_error("SetupOpenInfFile failed") 
    end
    
    local ids = {}
    local context = ffi.new("INFCONTEXT")
    local buf = ffi.new("wchar_t[512]")
    local req_size = ffi.new("DWORD[1]")
    
    -- 1. 查找 [Manufacturer] 节
    if setupapi.SetupFindFirstLineW(hInf, util.to_wide("Manufacturer"), nil, context) ~= 0 then
        repeat
            -- 每一行: ManufacturerName = ModelsSectionName
            -- Field 1 是 Models 节的名称基础 (例如 "Intel")
            if setupapi.SetupGetStringFieldW(context, 1, buf, 512, nil) ~= 0 then
                local models_base_name = util.from_wide(buf)
                
                -- 2. 确定需要扫描的 Models 节变体 (Decorations)
                -- Windows 驱动会使用 .NTamd64, .NTx86 等后缀区分架构
                local sections_to_scan = { models_base_name } -- 总是扫描未修饰的基础名
                
                if ffi.arch == "x64" then
                    table.insert(sections_to_scan, models_base_name .. ".NTamd64")
                elseif ffi.arch == "x86" then
                    table.insert(sections_to_scan, models_base_name .. ".NTx86")
                elseif ffi.arch == "arm64" then
                    table.insert(sections_to_scan, models_base_name .. ".NTarm64")
                end
                
                -- 保存当前的 Manufacturer 上下文，因为我们要去遍历 Models
                local mfg_context_backup = ffi.new("INFCONTEXT")
                ffi.copy(mfg_context_backup, context, ffi.sizeof("INFCONTEXT"))
                
                -- 3. 遍历 Models 节
                for _, sec_name in ipairs(sections_to_scan) do
                    local model_ctx = ffi.new("INFCONTEXT")
                    
                    if setupapi.SetupFindFirstLineW(hInf, util.to_wide(sec_name), nil, model_ctx) ~= 0 then
                        repeat
                            -- Models 节的一行: Device Description = Install Section, HWID, CompatID...
                            -- Field 0: Key (Device Desc)
                            -- Field 1: Install Section Name
                            -- Field 2+: Hardware IDs / Compatible IDs
                            
                            local field_idx = 2
                            while setupapi.SetupGetStringFieldW(model_ctx, field_idx, buf, 512, nil) ~= 0 do
                                local hwid = util.from_wide(buf)
                                if hwid and hwid ~= "" then
                                    ids[hwid:upper()] = true
                                end
                                field_idx = field_idx + 1
                            end
                        until setupapi.SetupFindNextLine(model_ctx, model_ctx) == 0
                    end
                end
                
                -- 恢复 Manufacturer 上下文以继续外层循环
                ffi.copy(context, mfg_context_backup, ffi.sizeof("INFCONTEXT"))
            end
        until setupapi.SetupFindNextLine(context, context) == 0
    end
    
    setupapi.SetupCloseInfFile(hInf)
    return ids
end

return M