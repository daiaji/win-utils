local M = {}

local modules = {
    -- [Core Infrastructure]
    core     = 'win-utils.core.util',
    
    -- [Main Modules]
    fs       = 'win-utils.fs.init',
    reg      = 'win-utils.reg.init',
    process  = 'win-utils.process.init',
    disk     = 'win-utils.disk.init',
    net      = 'win-utils.net.init',
    wim      = 'win-utils.wim',
    
    -- [System Sub-modules]
    sys = {
        service  = 'win-utils.sys.service',
        driver   = 'win-utils.sys.driver',
        power    = 'win-utils.sys.power',
        desktop  = 'win-utils.sys.desktop',
        display  = 'win-utils.sys.display',
        shortcut = 'win-utils.sys.shortcut',
        hotkey   = 'win-utils.sys.hotkey',
        info     = 'win-utils.sys.info', -- [ADDED]
    }
}

setmetatable(M, {
    __index = function(t, key)
        local val = modules[key]
        if not val then return nil end
        
        if type(val) == "table" then
            -- Handle nested tables (e.g. sys.power)
            local sub = {}
            setmetatable(sub, {
                __index = function(_, sub_k)
                    local path = val[sub_k]
                    if path then
                        local m = require(path)
                        rawset(sub, sub_k, m)
                        return m
                    end
                end
            })
            rawset(t, key, sub)
            return sub
        else
            -- Handle direct modules
            local m = require(val)
            rawset(t, key, m)
            return m
        end
    end
})

return M