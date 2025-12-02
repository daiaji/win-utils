local M = {}

M.defs     = require 'win-utils.disk.defs'
M.info     = require 'win-utils.disk.info'
M.safety   = require 'win-utils.disk.safety'
M.types    = require 'win-utils.disk.types'

M.physical = require 'win-utils.disk.physical'
M.layout   = require 'win-utils.disk.layout'
M.volume   = require 'win-utils.disk.volume'
M.vhd      = require 'win-utils.disk.vhd'

M.format   = require 'win-utils.disk.format'
M.vds      = require 'win-utils.disk.vds'
M.image    = require 'win-utils.disk.image'
M.mount    = require 'win-utils.disk.mount'

M.list_drives  = M.info.list_physical_drives
M.list_volumes = M.volume.list
M.open         = M.physical.open

return M