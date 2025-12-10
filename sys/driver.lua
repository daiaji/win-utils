local ffi = require 'ffi'
local bit = require 'bit'
local newdev = require 'ffi.req' 'Windows.sdk.newdev'
local setupapi = require 'ffi.req' 'Windows.sdk.setupapi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll'
local util = require 'win-utils.core.util'
local native = require 'win-utils.core.native'
local token = require 'win-utils.process.token'
local fs = require 'win-utils.fs.init'

local M = {}

-- 加载驱动服务 (.sys)
function M.load(path)
    if not token.enable_privilege("SeLoadDriverPrivilege") then return false, "SeLoadDriverPrivilege required" end
    local oa, a = native.init_object_attributes("\\Registry\\Machine\\System\\CurrentControlSet\\Services\\"..path)
    local r = ntdll.NtLoadDriver(oa)
    local _ = a
    if r < 0 then return false, string.format("NtLoadDriver failed: 0x%X", r) end
    return true
end

-- 卸载驱动服务
function M.unload(path)
    if not token.enable_privilege("SeLoadDriverPrivilege") then return false, "SeLoadDriverPrivilege required" end
    local oa, a = native.init_object_attributes("\\Registry\\Machine\\System\\CurrentControlSet\\Services\\"..path)
    local r = ntdll.NtUnloadDriver(oa)
    local _ = a
    if r < 0 then return false, string.format("NtUnloadDriver failed: 0x%X", r) end
    return true
end

-- 安装 INF 驱动
function M.install(inf, force)
    local rb = ffi.new("BOOL[1]")
    -- DiInstallDriverW
    if newdev.DiInstallDriverW(nil, util.to_wide(inf), 0, rb) == 0 then
        return false, util.last_error("DiInstallDriver failed")
    end
    return true, rb[0] ~= 0 -- Result, RebootRequired
end

-- 更新指定设备的驱动
function M.update_device(hwid, inf, force)
    local rb = ffi.new("BOOL[1]")
    if newdev.UpdateDriverForPlugAndPlayDevicesW(nil, util.to_wide(hwid), util.to_wide(inf), force and 1 or 0, rb) == 0 then
        return false, util.last_error("UpdateDriver failed")
    end
    return true, rb[0] ~= 0
end

-- 仅添加到驱动存储区
function M.add_to_store(inf)
    if setupapi.SetupCopyOEMInfW(util.to_wide(inf), nil, 1, 0, nil, 0, nil, nil) == 0 then
        return false, util.last_error("SetupCopyOEMInf failed")
    end
    return true
end

-- [ENHANCED] 解压 CAB 驱动包
-- 注意：此函数仅负责解压，不负责递归安装。递归逻辑请在业务层实现。
-- @param cab_path: .cab 文件路径
-- @param dest_dir: 解压临时目录 (可选，默认 %TEMP%\Drv_<Random>)
-- @param progress_cb: (可选) function(stage, filename, size)
--        stage: "extracting"
--        return false from cb to abort
-- @return: success, result_table (包含 extracted_path) 或 error_msg
function M.install_cab(cab_path, dest_dir, progress_cb)
    if not fs.exists(cab_path) then return false, "CAB file not found" end
    
    local target_dir = dest_dir
    local auto_generated = false
    
    if not target_dir then
        target_dir = os.getenv("TEMP") .. "\\Drv_" .. os.time() .. "_" .. math.random(1000)
        auto_generated = true
    end
    
    -- 确保目标目录存在
    if not fs.mkdir(target_dir, {p=true}) then
        return false, "Failed to create target directory"
    end
    
    -- 1. 定义回调函数解压文件
    local callback = ffi.cast("PSP_FILE_CALLBACK_W", function(context, notification, param1, param2)
        if notification == 0x11 then -- SPFILENOTIFY_FILEINCABINET
            local info = ffi.cast("PFILE_IN_CABINET_INFO_W", param1)
            local filename = util.from_wide(info.NameInCabinet)
            local filesize = tonumber(info.FileSize)
            
            -- [NEW] 调用 Lua 进度回调
            if progress_cb then
                local continue = true
                -- 使用 xpcall 防止回调报错导致 C 栈崩溃
                xpcall(function() 
                    if progress_cb("extracting", filename, filesize) == false then
                        continue = false
                    end
                end, function(err) print("Progress CB Error: "..tostring(err)) end)
                
                if not continue then return 0 end -- FILEOP_ABORT
            end
            
            -- 构建目标路径: target_dir \ filename
            -- CAB 内可能有子目录结构，需转换 / 为 \ 并创建父目录
            local full_path = target_dir .. "\\" .. filename:gsub("/", "\\")
            
            -- 确保父目录存在
            local parent = full_path:match("(.*)\\[^\\]+$")
            if parent then fs.mkdir(parent, {p=true}) end
            
            local w_full_path = util.to_wide(full_path)
            ffi.copy(info.FullTargetName, w_full_path, ffi.sizeof(w_full_path))
            
            return 1 -- FILEOP_DOIT
        end
        return 0 -- NO_ERROR
    end)
    
    -- 2. 执行解压
    local res = setupapi.SetupIterateCabinetW(util.to_wide(cab_path), 0, callback, nil)
    callback:free() -- 释放回调
    
    if res == 0 then 
        -- 如果失败且是我们自动创建的目录，清理掉
        if auto_generated then fs.delete(target_dir) end
        return false, util.last_error("SetupIterateCabinet failed") 
    end
    
    -- 3. 成功返回解压路径，不再调用 scanner (解耦)
    return true, { extracted_path = target_dir }
end

return M