local M = {}

M.fmifs = require 'win-utils.disk.format.fmifs'
M.fat32 = require 'win-utils.disk.format.fat32'

-- Default format entry point
-- Falls back to fmifs for standard usage, matching original API
M.format = M.fmifs.format

return M