local M = {}

-- Windows Native Network Utilities (FFI Pure Implementation)
-- 这些模块直接调用系统 API (iphlpapi, dnsapi 等)，完全不依赖第三方 socket 库

-- 网卡列表与配置信息 (IP, MAC, Status)
M.adapter = require 'win-utils.net.adapter'

-- ICMP Ping 工具
M.icmp    = require 'win-utils.net.icmp'

-- 网络连接状态 (Netstat - TCP Table)
M.stat    = require 'win-utils.net.stat'

-- DNS 工具 (如刷新缓存)
M.dns     = require 'win-utils.net.dns'

return M