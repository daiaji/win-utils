local M          = {}

-- 1. Base Utilities
M.util           = require 'win-utils.util'
M.error          = require 'win-utils.error'
M.handle         = require 'win-utils.handle'

-- 2. System APIs
M.registry       = require 'win-utils.registry'
M.shortcut       = require 'win-utils.shortcut'
M.net            = require 'win-utils.net'
M.fs             = require 'win-utils.fs'
M.shell          = require 'win-utils.shell'
M.hotkey         = require 'win-utils.hotkey'

-- 3. Process Management
M.process        = require 'win-utils.process'
M.process.handle = require 'win-utils.process.handle' -- Handle hunting

-- 4. Device & Hardware
M.device         = require 'win-utils.device' -- Device Cycling/Reset

-- 5. Enhanced DiskPart (Core Logic)
M.disk           = require 'win-utils.disk'

-- Export Submodules for direct access if needed
M.disk.physical  = require 'win-utils.disk.physical'
M.disk.volume    = require 'win-utils.disk.volume'
M.disk.layout    = require 'win-utils.disk.layout'
M.disk.vds       = require 'win-utils.disk.vds'
M.disk.vhd       = require 'win-utils.disk.vhd'
M.disk.types     = require 'win-utils.disk.types'

-- Enhanced Operations (High Level)
M.disk.op        = require 'win-utils.disk.operation'
M.disk.esp       = require 'win-utils.disk.esp'
M.disk.badblocks = require 'win-utils.disk.badblocks'

-- Alias for legacy compatibility
M.get_last_error = M.util.format_error

return M