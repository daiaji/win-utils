local M = {}

local sub_modules = {
    adapter = 'win-utils.net.adapter',
    dns     = 'win-utils.net.dns',
    icmp    = 'win-utils.net.icmp',
    stat    = 'win-utils.net.stat'
}

setmetatable(M, {
    __index = function(t, key)
        local path = sub_modules[key]
        if path then
            local mod = require(path)
            rawset(t, key, mod)
            return mod
        end
        return nil
    end
})

return M