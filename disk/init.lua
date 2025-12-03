local M = {}

-- 静态引入，防止元表干扰
local volume = require 'win-utils.disk.volume'

-- 惰性加载其他子模块
local lazy = {
    info      = "win-utils.disk.info",
    physical  = "win-utils.disk.physical",
    layout    = "win-utils.disk.layout",
    vds       = "win-utils.disk.vds",
    vhd       = "win-utils.disk.vhd",
    format    = "win-utils.disk.format.init",
    badblocks = "win-utils.disk.badblocks",
    types     = "win-utils.disk.types",
    defs      = "win-utils.disk.defs",
    safety    = "win-utils.disk.safety",
    subst     = "win-utils.disk.subst",
    mount     = "win-utils.disk.mount",
    esp       = "win-utils.disk.esp",
    op        = "win-utils.disk.operation"
}

setmetatable(M, {
    __index = function(t, k)
        if k == "volume" then
            rawset(t, k, volume)
            return volume
        elseif lazy[k] then
            local mod = require(lazy[k])
            rawset(t, k, mod)
            return mod
        end
        return nil
    end
})

return M