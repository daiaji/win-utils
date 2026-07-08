local M = {}

-- [Lua-Ext Integration]
-- 确保基础扩展被加载 (这些是 win-utils 依赖的基础)
require 'ext.table'
require 'ext.string'
require 'ext.math'

local modules = {
    -- [Core Infrastructure]
    core     = 'win-utils.core.util',
    
    -- [Main Modules]
    fs       = 'win-utils.fs.init',
    reg      = 'win-utils.reg.init',
    process  = 'win-utils.process.init',
    disk     = 'win-utils.disk.init',
    net      = 'win-utils.net.init',
    sys      = 'win-utils.sys.init',
    
    -- [Standalone Modules]
    wim      = 'win-utils.wim',
    device   = 'win-utils.device',
    crypto   = 'win-utils.crypto',
    log      = 'win-utils.log',
    ini      = 'win-utils.ini',
    vk       = 'win-utils.vk',
    input    = 'win-utils.input',
    window   = 'win-utils.window',

    -- [NEW] Text Encoding (CODE)
    text     = 'win-utils.text'
}

setmetatable(M, {
    __index = function(t, key)
        local path = modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

return M
