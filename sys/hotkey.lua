local ffi = require 'ffi'
local user32 = require 'ffi.req' 'Windows.sdk.user32'
local M = {}
function M.reg(id, mod, key) user32.RegisterHotKey(nil, id, mod, key) end
return M