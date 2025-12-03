local M = {}
M.fmifs = require 'win-utils.disk.format.fmifs'
M.fat32 = require 'win-utils.disk.format.fat32'
M.format = M.fmifs.format
return M