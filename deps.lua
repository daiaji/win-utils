local M = {}

-- [Lua-Ext Integration]
-- 统一管理 lua-ext 依赖
M.class = require 'ext.class'

-- 启用全局增强 (String +, Table methods)
-- 这属于 win-utils 框架层面的设计决策，旨在提升开发效率
require 'ext.string'
require 'ext.table'
require 'ext.math'

return M