local M = {}

print("[DEBUG] Loading win-utils root (Eager Mode)...")

-- 1. 核心模块 (立即加载)
M.util   = require 'win-utils.util'
M.handle = require 'win-utils.handle'
M.native = require 'win-utils.native'

-- 2. 所有模块立即加载 (Eager Load) 以便于调试
local modules = {
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

for name, path in pairs(modules) do
    print(string.format("[DEBUG] Requiring module: %-10s -> %s", name, path))
    local ok, mod = pcall(require, path)
    if not ok then
        print("[ERROR] Failed to load " .. path .. ": " .. tostring(mod))
        error(mod)
    end
    M[name] = mod
end

print("[DEBUG] win-utils root loaded successfully.")
return M