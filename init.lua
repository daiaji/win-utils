local M = {}

print("[DEBUG] Loading win-utils root (Lazy Mode)...")

local modules = {
    util     = 'win-utils.util',
    handle   = 'win-utils.handle',
    native   = 'win-utils.native',
    
    registry = 'win-utils.registry',
    shortcut = 'win-utils.shortcut',
    fs       = 'win-utils.fs.init',
    shell    = 'win-utils.shell',
    hotkey   = 'win-utils.hotkey',
    service  = 'win-utils.service',
    display  = 'win-utils.display',
    desktop  = 'win-utils.desktop',
    driver   = 'win-utils.driver',
    wim      = 'win-utils.wim',
    net      = 'win-utils.net.init',
    process  = 'win-utils.process.init',
    device   = 'win-utils.device',
    disk     = 'win-utils.disk.init',
    power    = 'win-utils.power',
    scope    = 'win-utils.scope'
}

setmetatable(M, {
    __index = function(t, key)
        local path = modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod) -- Cache result
            return mod
        end
        return nil
    end
})

return M