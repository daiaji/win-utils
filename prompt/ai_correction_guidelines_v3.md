# **System Protocol: LuaJIT FFI & C++ Interop Core Guidelines (v3.1)**

**Context:** 本文档定义了 LuaJIT (v2.1) + C/C++ 混合架构的最高代码准则。
**Environment:**
*   **Lua Runtime:** LuaJIT 2.1 (基于 Lua 5.1 ABI)。**注意：绝非 Lua 5.3/5.4**。
*   **Host Language:** C/C++ (MSVC/GCC).
*   **Highest Priority:** 二进制兼容性 (ABI Safety) > 内存安全 (Memory Safety) > 性能。

**Usage:** 本文档作为生成模型的“思维链（Chain of Thought）”检查清单，必须在编码前逐条核对。

---

## **核心推理协议 (Core Reasoning Protocol)**

依据 *Step-Back Prompting* 理论，在生成或修改代码前，**必须** 按顺序执行以下逻辑自检：

1.  **🕵️ Context & Docs First:** "我是否已经查看了项目根目录下的 `docs/` 文件夹？"
    *   **Rule:** 项目文档（`docs/*.md`）和代码注释是唯一真理。如果文档规定了特定的 API 模式，**必须** 遵循文档。
2.  **🚧 Syntax Guard:** "代码中是否存在 Lua 5.3+ 符号 (`|`, `//`, `_ENV`)？"
    *   **Rule:** 必须拦截所有不兼容语法，并自动转换为 LuaJIT 兼容写法。
3.  **💀 GC Anchor Check (Critical):** "我是否将临时的 `cdata` 指针赋值给了结构体成员？"
    *   **Rule:** **这是最常见的崩溃源。** 赋值给 C 结构体指针成员只是拷贝地址，不拷贝对象。必须在 Lua 作用域内持有该对象的引用，直到 C 函数调用结束。
4.  **🔢 Precision Guard:** "我是否在定义 64 位掩码/常量？"
    *   **Rule:** Lua 的 `number` 是 `double`，只有 53 位精度。定义 >53 位的常量必须加 `ULL` 后缀（如 `0x80...ULL`）。
5.  **🔠 Encoding Guard:** "传递给 Windows API 的字符串是否已转为 UTF-16？"
    *   **Rule:** 严禁将 Lua 字符串直接强转为 `wchar_t*`。必须使用 `util.to_wide`。

---

## **指令一：`ffi.cdef` 语法清洗 (C-Syntax Only)**

**Context:** `ffi.cdef[[ ... ]]` 内部由 LuaJIT 的 C 解析器处理，它**不懂 Lua 语法**，也**不懂 C 预处理器**。

### **1. 注释风格 (Comment Style)**
*   **❌ 致命错误:** 使用 Lua 注释 `--`。会导致解析器崩溃。
*   **✅ 唯一正确:** 使用 C 注释 `//` 或 `/* ... */`。

### **2. 预处理幻觉 (Preprocessor Hallucination)**
*   **❌ 致命错误:** 直接粘贴 `#include`, `#ifdef`, `#ifndef`, 复杂 `#define`。
*   **✅ 唯一正确:** 手动清洗代码，将宏转为 `enum` 或 `static const`，手动展开结构体与 typedef。

---

## **指令二：精准的 LuaJIT 语法控制 (White/Black List)**

**Context:** LuaJIT 不是 Lua 5.3。严禁使用不被支持的语法。

### **❌ 严禁使用的特性 (Lua 5.3+ Hallucinations)**
| 错误写法 (Trap)    | ✅ 修正写法                | 原因                     |
| :----------------- | :------------------------ | :----------------------- |
| `val = a           | b`                        | `val = bit.bor(a, b)`    | 不支持 5.3 运算符 |
| `val = a << 1`     | `val = bit.lshift(a, 1)`  | 同上                     |
| `val = a // b`     | `val = math.floor(a / b)` | 不支持整除符号           |
| `local _ENV = ...` | `setfenv(1, env)`         | **LuaJIT 不支持 `_ENV`** |
| `handle = ...`     | `local handle = ...`      | **严禁隐式全局变量**     |

### **✅ 推荐使用的特性 (LuaJIT Extensions)**
| 场景           | 推荐写法                   | 说明                     |
| :------------- | :------------------------- | :----------------------- |
| **位运算**     | `require("bit")`           | LuaJIT 内置高性能库      |
| **字符串拼接** | `require("string.buffer")` | (v2.1+) 零拷贝，支持 FFI |
| **参数打包**   | `table.pack(...)`          | 5.2 兼容                 |
| **Try-Catch**  | `xpcall(f, err, args...)`  | 5.2 兼容，支持传参       |

---

## **指令三：显式的 FFI 库加载 (Library Whitelist)**

**Context:** `ffi.C` **不包含**所有系统 API。不要让 LLM 猜测，必须显式加载。

### **1. ✅ 核心库 (无需加载)**
*   **Windows:** `kernel32`, `user32`, `gdi32`, `msvcrt`。
*   **POSIX:** `libc`, `libm`, `libpthread`, `libdl`。

### **2. ❌ 必须 `ffi.load` 的库 (必须显式加载)**
| API            | 所在库     | ❌ 错误         | ✅ 正确                                         |
| :------------- | :--------- | :------------- | :--------------------------------------------- |
| `RegOpenKey`   | `advapi32` | `ffi.C.Reg...` | `local adv = ffi.load("advapi32"); adv.Reg...` |
| `CoInitialize` | `ole32`    | `ffi.C.Co...`  | `local ole = ffi.load("ole32"); ole.Co...`     |
| `socket`       | `ws2_32`   | `ffi.C.socket` | `local ws = ffi.load("ws2_32"); ws.socket`     |

---

## **指令四：内存安全与 GC 锚定 (Life-Saving Protocols)**

这是 LuaJIT FFI 编程中最容易导致崩溃的部分。

### **1. 结构体指针赋值陷阱 (The Struct Field Trap)**
**Rule:** 当将 Lua 侧生成的 `cdata` (如数组、宽字符串) 赋值给 C 结构体的指针成员时，Lua 变量必须在 C 函数调用期间保持存活。

*   **❌ 致命错误 (Heisenbug):**
    ```lua
    local struct = ffi.new("MY_STRUCT")
    -- util.to_wide 返回一个新的 cdata，赋值后 Lua 失去了对它的引用！
    -- GC 可能会在 C 函数执行前回收它，导致 struct.ptr 指向野指针。
    struct.ptr = util.to_wide("string") 
    C.DoWork(struct)
    ```
*   **✅ 正确写法 (GC Anchor):**
    ```lua
    local struct = ffi.new("MY_STRUCT")
    -- 1. 创建局部变量持有引用 (Anchor)
    local anchor_str = util.to_wide("string")
    -- 2. 赋值地址
    struct.ptr = anchor_str
    -- 3. 调用 C 函数
    C.DoWork(struct)
    -- 4. 函数返回前，anchor_str 都在作用域内，不会被 GC
    ```

### **2. 异步回调锚定 (Async Anchoring)**
**Rule:** 传递给 C 的异步/长期回调函数，必须在 Lua 表中锚定。
```lua
local anchors = {} -- 模块级锚点表
function M.reg(id)
    local cb = ffi.cast("CALLBACK_T", function(...) end)
    table.insert(anchors, cb) -- ✅ Prevent GC
    C.AsyncOp(cb)
end
```

### **3. 强制区分数组索引**
*   **Lua Table:** Index starts at **1**.
*   **FFI Pointer/Array:** Index starts at **0**.

---

## **指令五：C++ 宿主防御范式**

**Rule:** C++ 端必须严格检查 Lua 传递的指针类型。

```cpp
// ✅ C++ Defensive Pattern
#ifndef LUA_TCDATA
#define LUA_TCDATA 10 
#endif

void HandlePtr(lua_State* L, int idx) {
    // 1. Type Check
    if (lua_type(L, idx) != LUA_TCDATA) {
        luaL_error(L, "Expected cdata, got %s", luaL_typename(L, idx));
    }
    // 2. Safe Cast (use lua_topointer, NOT touserdata)
    // lua_touserdata returns NULL for cdata!
    void* p = const_cast<void*>(lua_topointer(L, idx));
}
```

---

## **指令六：双向契约同步 (Cross-Boundary Sync)**

**Rule:** 当修改 Lua/C++ 边界时，必须检查另一端：
1.  **Lua -> C++:** 新增 `native.call` 时，检查 C++ 端的消息分发逻辑。
2.  **C++ -> Lua:** C++ 回调参数变更时，同步更新 Lua 端 `ffi.cast` 的签名。

---

## **指令七：代码完整性与版本控制协议**

### **1. 风格与注释零侵入**
*   **Rule:** 严格遵循原始代码的缩进与格式。
*   **Rule:** **严格保留原有注释**。禁止删除现有注释。

### **2. 测试覆盖率铁律**
*   **Rule:** 禁止删除测试用例。如果功能变更，必须修正断言而非注释代码。

---

## **指令八：数值精度与编码规范 (Data Integrity)**

### **1. 64 位常量精度 (The 53-bit Trap)**
**Rule:** Lua 的 `number` (double) 只有 53 位尾数精度。定义 64 位掩码或常量时，必须使用 `ULL` 后缀。
*   **❌ 错误:** `local FLAG = 0x8000000000000000` (解析为 double，可能丢失低位或变成负数/Inf)。
*   **✅ 正确:** `local FLAG = 0x8000000000000000ULL` (解析为 `uint64_t` cdata)。

### **2. Windows 字符串编码**
**Rule:** Windows API (W后缀) 需要 UTF-16。严禁将 Lua 字符串直接强转。
*   **❌ 错误:** `C.CreateFileW(ffi.cast("wchar_t*", "C:\\Path"), ...)` -> 乱码/失败。
*   **✅ 正确:** `C.CreateFileW(util.to_wide("C:\\Path"), ...)`。

---

## **指令九：性能敏感路径规范 (Performance Critical Paths)**

### **1. 循环外分配 (Hoist Allocations)**
**Rule:** 在重试循环（如文件锁竞争、网络重试）中，禁止进行无意义的 `cdata` 分配。
*   **❌ 低效:**
    ```lua
    for i = 1, 100 do
        -- 每次循环都分配新的内存和 GC 对象
        local wpath = util.to_wide(path) 
        C.TryOpen(wpath)
    end
    ```
*   **✅ 高效:**
    ```lua
    -- 循环外只分配一次
    local wpath = util.to_wide(path)
    for i = 1, 100 do
        C.TryOpen(wpath)
    end
    ```