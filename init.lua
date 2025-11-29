local M          = {}

M.util           = require 'win-utils.util'
M.registry       = require 'win-utils.registry'
M.shortcut       = require 'win-utils.shortcut'
M.net            = require 'win-utils.net'
M.fs             = require 'win-utils.fs'
M.shell          = require 'win-utils.shell'
M.disk           = require 'win-utils.disk'
M.hotkey         = require 'win-utils.hotkey'
M.error          = require 'win-utils.error'
M.proc           = require 'win-utils.proc'

-- 方便直接访问常用工具
M.get_last_error = M.util.format_error

return M
