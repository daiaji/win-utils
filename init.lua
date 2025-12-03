local M = {}

-- 1. 核心模块 (立即加载)
M.util   = require 'win-utils.util'
M.handle = require 'win-utils.handle'
M.native = require 'win-utils.native'

-- 2. 惰性加载映射
local lazy_modules = {
    registry = 'win-utils.registry',
    shortcut = 'win-utils.shortcut',
    fs       = 'win-utils.fs',
    shell    = 'win-utils.shell',
    hotkey   = 'win-utils.hotkey',
    service  = 'win-utils.service',
    display  = 'win-utils.display',
    desktop  = 'win-utils.desktop',
    driver   = 'win-utils.driver',
    pagefile = 'win-utils.system.pagefile',
    wim      = 'win-utils.wim',
    net      = 'win-utils.net',
    process  = 'win-utils.process',
    device   = 'win-utils.device',
    disk     = 'win-utils.disk',
    power    = 'win-utils.power',
    scope    = 'win-utils.scope'
}

setmetatable(M, {
    __index = function(t, k)
        local path = lazy_modules[k]
        if path then
            local mod = require(path)
            rawset(t, k, mod)
            return mod
        end
        return nil
    end
})

return M