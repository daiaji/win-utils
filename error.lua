local M = {}
local util = require 'win-utils.util'

-- 此模块保留是为了保持向后兼容性，逻辑已下沉至 util.lua
function M.get_last_error(err_code)
    return util.format_error(err_code)
end

return M
