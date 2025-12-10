local ffi = require 'ffi'
local bit = require 'bit'
local shell32 = require 'ffi.req' 'Windows.sdk.shell32'
local ole32 = require 'ffi.req' 'Windows.sdk.ole32'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local util = require 'win-utils.core.util'

local M = {}

-- ShowCommand 常量映射
local SHOW_CMD = {
    normal = 1, -- SW_SHOWNORMAL
    max    = 3, -- SW_SHOWMAXIMIZED
    min    = 7  -- SW_SHOWMINNOACTIVE
}

-- 辅助：解析热键字符串 "Ctrl+Alt+K" -> Word (低8位Key, 高8位Mod)
-- Modifiers: SHIFT(1), CTRL(2), ALT(4), EXT(8)
local function parse_hotkey(str)
    if not str then return 0 end
    local mod = 0
    local key = 0
    local s = str:upper()
    
    if s:find("SHIFT") then mod = bit.bor(mod, 1) end -- HOTKEYF_SHIFT
    if s:find("CTRL")  then mod = bit.bor(mod, 2) end -- HOTKEYF_CONTROL
    if s:find("ALT")   then mod = bit.bor(mod, 4) end -- HOTKEYF_ALT
    
    -- 提取最后一个字符或键码
    -- 匹配最后一个单词或数字
    local last = s:match("[%w]+$")
    if last then
        if #last == 1 then
            -- 单字符 A-Z, 0-9
            key = user32.VkKeyScanW(string.byte(last)) 
            key = bit.band(key, 0xFF)
        elseif last:match("^F%d+") then
            -- 功能键 F1-F12
            local n = tonumber(last:sub(2))
            if n and n >= 1 and n <= 12 then key = 0x70 + (n - 1) end -- VK_F1 ...
        elseif last == "ENTER" then key = 0x0D
        elseif last == "ESC" then key = 0x1B
        elseif last == "SPACE" then key = 0x20
        elseif last == "TAB" then key = 0x09
        elseif last == "BACK" then key = 0x08
        end
    end
    
    if key == 0 then return 0 end
    return bit.bor(bit.lshift(mod, 8), key)
end

-- [API] 创建快捷方式
-- @param path: .lnk 文件路径
-- @param opts: 配置表
--    opts.target   (必填) 目标文件路径
--    opts.args     (可选) 参数
--    opts.work_dir (可选) 工作目录 (默认自动设为 target 所在目录)
--    opts.desc     (可选) 备注
--    opts.icon     (可选) 图标文件路径
--    opts.icon_idx (可选) 图标索引 (默认 0)
--    opts.show     (可选) "normal", "max", "min"
--    opts.hotkey   (可选) "Ctrl+Alt+E"
function M.create(path, opts)
    if type(opts) ~= "table" then return false, "Options table required" end
    if not opts.target then return false, "Target required" end

    -- 自动补全 .lnk
    local lnk_path = path
    if not lnk_path:match("%.[lL][nN][kK]$") then lnk_path = lnk_path .. ".lnk" end

    ole32.CoInitialize(nil)
    
    local ppObj = ffi.new("void*[1]")
    local hr = ole32.CoCreateInstance(shell32.CLSID_ShellLink, nil, 1, shell32.IID_IShellLinkW, ppObj)
    if hr < 0 then 
        ole32.CoUninitialize()
        return false, string.format("CoCreateInstance failed: 0x%X", hr)
    end
    
    local sl = ffi.cast("IShellLinkW*", ppObj[0])
    
    -- 1. 设置目标
    sl.lpVtbl.SetPath(sl, util.to_wide(opts.target))
    
    -- 2. 设置参数
    if opts.args then sl.lpVtbl.SetArguments(sl, util.to_wide(opts.args)) end
    
    -- 3. 设置工作目录 (默认跟随目标)
    local work_dir = opts.work_dir
    if not work_dir then
        local fs_path = require('win-utils.fs.path') -- 延迟加载避免循环依赖
        work_dir = fs_path.dirname(opts.target)
    end
    if work_dir then sl.lpVtbl.SetWorkingDirectory(sl, util.to_wide(work_dir)) end
    
    -- 4. 设置描述
    if opts.desc then sl.lpVtbl.SetDescription(sl, util.to_wide(opts.desc)) end
    
    -- 5. 设置显示模式
    if opts.show then
        local cmd = SHOW_CMD[opts.show:lower()] or 1
        sl.lpVtbl.SetShowCmd(sl, cmd)
    end
    
    -- 6. 设置图标
    if opts.icon then 
        sl.lpVtbl.SetIconLocation(sl, util.to_wide(opts.icon), opts.icon_idx or 0) 
    end
    
    -- 7. 设置热键
    if opts.hotkey then
        local hk_val = parse_hotkey(opts.hotkey)
        if hk_val ~= 0 then sl.lpVtbl.SetHotkey(sl, hk_val) end
    end
    
    -- 8. 保存
    local res = true
    local err = nil
    
    local ppPf = ffi.new("void*[1]")
    if sl.lpVtbl.QueryInterface(sl, shell32.IID_IPersistFile, ppPf) >= 0 then
        local pf = ffi.cast("IPersistFile*", ppPf[0])
        -- true = fRemember (使用该路径作为当前文件)
        local save_hr = pf.lpVtbl.Save(pf, util.to_wide(lnk_path), 1)
        if save_hr < 0 then
            res = false
            err = string.format("Save failed: 0x%X", save_hr)
        end
        pf.lpVtbl.Release(pf)
    else
        res = false
        err = "QueryInterface IPersistFile failed"
    end
    
    sl.lpVtbl.Release(sl)
    
    -- 不调用 CoUninitialize，避免干扰宿主程序的 COM 状态
    -- ole32.CoUninitialize() 
    
    return res, err
end

return M