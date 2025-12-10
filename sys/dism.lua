local ffi = require 'ffi'
local util = require 'win-utils.core.util'
local fs = require 'win-utils.fs.init'
local dismapi = require 'ffi.req' 'Windows.sdk.dismapi'

local M = {}

-- [API] 向离线 Windows 镜像注入驱动
-- @param image_path: 离线镜像根目录 (例如 "D:\Mount")
-- @param driver_path: INF 文件路径 或 包含驱动的文件夹路径
-- @param opts:
--    opts.force_unsigned (bool): 强制安装未签名驱动 (默认 false)
--    opts.recurse (bool): 如果是文件夹，是否递归扫描 (默认 true)
-- @return: boolean success, table result_or_error_msg
function M.add_driver_offline(image_path, driver_path, opts)
    opts = opts or {}
    
    -- 1. 打开 DISM 会话
    -- 初始化 DISM (只需一次)
    -- LogFilePath=NULL, ScratchDir=NULL (Use Default)
    local hr_init = dismapi.DismInitialize(0, nil, nil)
    if hr_init < 0 then 
        return false, string.format("DismInitialize failed: 0x%X", hr_init) 
    end

    local session = ffi.new("DismSession[1]")
    local hr = dismapi.DismOpenSession(util.to_wide(image_path), nil, nil, session)
    if hr < 0 then 
        dismapi.DismShutdown()
        return false, string.format("DismOpenSession failed: 0x%X", hr) 
    end
    
    local safe_session = session[0]
    local success_cnt = 0
    local fail_cnt = 0
    local errors = {}
    
    -- 内部辅助：安装单个 INF
    local function install_one(inf)
        local force = opts.force_unsigned and 1 or 0
        local hr_add = dismapi.DismAddDriver(safe_session, util.to_wide(inf), force)
        
        if hr_add >= 0 then
            success_cnt = success_cnt + 1
            return true
        else
            fail_cnt = fail_cnt + 1
            local msg = string.format("0x%X", hr_add)
            table.insert(errors, inf .. ": " .. msg)
            return false
        end
    end
    
    -- 2. 执行安装逻辑
    if fs.is_dir(driver_path) then
        -- 文件夹模式：需要手动遍历，因为 DismAddDriver API 仅接受 INF 文件路径
        -- (注：dism.exe 命令行支持 /Recurse，但 API 层面通常需调用者提供路径)
        local function walk(dir)
            for name, attr in fs.scandir(dir) do
                if name ~= "." and name ~= ".." then
                    local full = dir .. "\\" .. name
                    local is_dir = bit.band(attr, 0x10) ~= 0
                    
                    if is_dir then
                        if opts.recurse ~= false then walk(full) end
                    else
                        if name:match("%.[iI][nN][fF]$") then
                            install_one(full)
                        end
                    end
                end
            end
        end
        walk(driver_path)
    else
        -- 单文件模式
        install_one(driver_path)
    end
    
    -- 3. 关闭会话
    dismapi.DismCloseSession(safe_session)
    dismapi.DismShutdown()
    
    -- 4. 结果判定
    if fail_cnt > 0 and success_cnt == 0 then
        return false, "All drivers failed", errors
    end
    
    return true, { success = success_cnt, fail = fail_cnt, errors = errors }
end

-- [API] 关闭 DISM (通常在程序退出前调用)
function M.shutdown()
    dismapi.DismShutdown()
end

return M