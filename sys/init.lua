local M = {}

local sub_modules = {
    service  = 'win-utils.sys.service',
    driver   = 'win-utils.sys.driver',
    power    = 'win-utils.sys.power',
    desktop  = 'win-utils.sys.desktop',
    display  = 'win-utils.sys.display',
    shortcut = 'win-utils.sys.shortcut',
    hotkey   = 'win-utils.sys.hotkey',
    info     = 'win-utils.sys.info',
    shell    = 'win-utils.sys.shell',
    io       = 'win-utils.sys.io',
    path     = 'win-utils.sys.path',
    env      = 'win-utils.sys.env',
    pagefile = 'win-utils.sys.pagefile',
    dism     = 'win-utils.sys.dism',
    inf      = 'win-utils.sys.inf',
    dev_info = 'win-utils.sys.dev_info',
    font     = 'win-utils.sys.font'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        
        -- [Shortcut] sys.tee
        if key == "tee" then
            local mod = require('win-utils.sys.io')
            rawset(t, "tee", mod.tee)
            return mod.tee
        end
        
        -- [Shortcut] sys.which
        if key == "which" then
            local mod = require('win-utils.sys.path')
            rawset(t, "which", mod.which)
            return mod.which
        end
        
        return nil
    end
})

return M