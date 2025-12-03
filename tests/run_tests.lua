local ffi = require 'ffi'

-- [CRITICAL] Disable JIT to prevent FFI stability issues during tests
-- Many FFI crashes/hangs are due to JIT compilation of bad cdefs or callbacks
if jit then 
    jit.off() 
    jit.flush()
    print("[INIT] JIT Disabled for stability.")
end

local luaunit = require('luaunit')

-- 强制刷新缓冲区，确保 CI 日志实时输出
io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

print("=== Win-Utils Test Suite (Complete Coverage) ===")
print("OS: " .. ffi.os)
print("Arch: " .. ffi.arch)

-- 1. 加载核心测试 (FS, Registry, Disk, Handle)
print("Loading: core_spec")
require 'win-utils.tests.core_spec'

-- 2. 加载进程测试 (Process, Token, Service, NetStat)
print("Loading: process_spec")
require 'win-utils.tests.process_spec'

-- 3. 加载扩展测试 (Network, Job, WIM, VHD, Desktop)
print("Loading: extra_spec")
require 'win-utils.tests.extra_spec'

-- 运行
os.exit(luaunit.LuaUnit.run())