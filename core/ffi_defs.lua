local ffi = require 'ffi'
-- 仅加载定义，不再包含任何 cdef
require 'ffi.req' 'Windows.sdk.minwindef'
require 'ffi.req' 'Windows.sdk.ntdll'
require 'ffi.req' 'Windows.sdk.winioctl'
require 'ffi.req' 'Windows.sdk.kernel32'

return ffi.C