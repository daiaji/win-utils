# **System Protocol: LuaJIT FFI & C++ Interop Core Guidelines (v3.4)**

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
6.  **🧩 Dependency Check:** "使用的类型（如 `NTSTATUS`, `PVOID`）在当前 `cdef` 中是否已定义？"
    *   **Rule:** FFI 不会自动导入系统头文件。不要假设 `minwindef` 包含所有类型。必须显式定义。

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
| `val = a | b`      | `val = bit.bor(a, b)`    | 不支持 5.3 运算符 |
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

---

## **指令十：FFI 命名空间与类型依赖铁律 (Namespace & Dependency Laws)**

**Context:** LuaJIT FFI 对命名空间和 C 声明顺序有严格要求，违背会导致 `nil` 错误或类型未定义崩溃。

### **1. FFI 命名空间分离 (Separation of Concerns)**
*   **机制:** `ffi.load` 返回的是 **库实例 (Library Instance)**，仅用于调用函数。`ffi.cdef` 定义的类型、枚举、常量全部挂载在全局 **`ffi.C`** 命名空间下。
*   **❌ 错误:** `local lib = ffi.load("mylib"); local val = lib.MY_CONST` (库实例不包含 C 声明)。
*   **✅ 正确:** `local lib = ffi.load("mylib"); local val = ffi.C.MY_CONST`。

### **2. 声明顺序 (Top-Down Declaration)**
*   **机制:** FFI 的 C 解析器是单遍的 (Single-pass)。
*   **Rule:** 必须先定义被依赖的类型，再定义使用它的结构体。
*   **❌ 错误:**
    ```c
    struct B { A member; }; // A 未定义，报错
    typedef struct { int x; } A;
    ```
*   **✅ 正确:**
    ```c
    typedef struct { int x; } A;
    struct B { A member; };
    ```

### **3. 禁止隐式类型 (No Implicit Types)**
*   **机制:** FFI 环境是裸环境，没有标准库头文件。
*   **Rule:** 不要假设 `SIZE_T`, `WCHAR`, `HMODULE`, `NTSTATUS` 等类型存在，除非显式 `typedef` 过。
*   **Action:** 在 `cdef` 顶部显式定义所有非基础类型。

---

## **指令十一：FFI 类型定义与解析器陷阱 (Type Definitions & Parser Pitfalls)**

**Context:** 针对 Windows FFI 绑定的常见错误总结。

### **1. Windows 扩展类型完备性 (Complete Type Specs)**
*   **错误:** `declaration specifier expected near 'NTSTATUS'` / `PCHAR` / `UINT8`。
*   **Rule:** FFI 默认不包含任何 Windows 扩展类型，也不包含 `NTSTATUS`。
*   **Action:** 必须在基础定义文件（如 `minwindef.lua`）中定义，或者在模块头部**显式补全**。
    ```c
    typedef LONG NTSTATUS; /* 必须显式定义! */
    typedef char *PCHAR;
    typedef void *SC_HANDLE;
    typedef unsigned char UINT8;
    ```

### **2. 避免结构体重复定义 (No Duplicate Structs)**
*   **错误:** `attempt to redefine 'STRUCT_NAME'`.
*   **Rule:** 如果两个模块（如 `kernel32` 和 `ntdll`）都需要同一个结构体（如 `IO_COUNTERS`），必须将其移动到**公共基础模块**（如 `minwindef`），并在上层模块中通过 `require` 引入，严禁重复定义。

### **3. 常量表达式限制 (Constant Expression Limits)**
*   **错误:** `invalid C type` at `static const SOCKET = (SOCKET)(~0)`.
*   **Rule:** FFI 的 `cdef` 解析器不支持在 `static const` 初始化中使用复杂的类型转换。
*   **Action:** 遇到复杂常量（尤其是 `-1` 或位取反），必须使用 `enum` 替代，或简化表达式。
    *   **❌ 错误:** `static const SOCKET INVALID = (SOCKET)(~0);`
    *   **✅ 正确:** `enum { INVALID = -1 };`

### **4. COM 接口定义链 (COM Chain)**
*   **Rule:** 定义 COM 接口时，必须先定义基类 `IUnknown` 及其 `Vtbl`，不能只做前向声明。

---

## **指令十二：常见报错与自修复 (Error Registry)**

**Context:** 遇到以下 FFI 报错时的标准修复动作。

### **1. 未定义类型 (Undefined Type)**
*   **Error:** `declaration specifier expected near 'NTSTATUS'` / `near 'PVOID'`
*   **Cause:** FFI 解析器找不到类型定义。即使依赖了 `minwindef`，如果 `minwindef` 没定义该类型（例如 `NTSTATUS` 通常不在 minwindef 中），也会报错。
*   **Action:** 立即在当前 `ffi.cdef` 的顶部添加 `typedef`。
    *   `NTSTATUS` -> `typedef LONG NTSTATUS;`
    *   `PVOID` -> `typedef void *PVOID;`

### **2. 符号未找到 (Symbol Not Found)**
*   **Error:** `cannot resolve symbol 'GetProcAddress'`
*   **Cause:** 函数名可能有 A/W 后缀，或者是宏。
*   **Action:** 检查 Windows API 文档，通常需要加 `W` (如 `GetProcAddress` 实际上通常绑定不到，它是 `kernel32` 的导出函数，但在 FFI 中最好直接用 `ffi.C.GetProcAddress` 如果已加载库，或者明确指定 `GetProcAddress` 仅针对 ANSI)。注意：大部分 Windows API 在 Lua 中应绑定 `W` 版本（如 `CreateFileW`）。

---

## **指令十三：参数位运算与枚举隔离 (Parameter Isolation)**

**Context:** C API 中不同参数的枚举值（Enum/Flag）可能具有相同的数值。

### **1. 严禁跨参数位运算合并 (No Cross-Param Bitwise OR)**
*   **陷阱:** `ParamA` 的 `FLAG_X` 值可能是 1，`ParamB` 的 `FLAG_Y` 值也可能是 1。
*   **错误:** `local flags = bit.bor(FLAG_X, FLAG_Y); Call(flags, flags)`。这将导致 `ParamB` 意外收到 `FLAG_Y` 的效果。
*   **案例:** `SetupCopyOEMInfW` 中，`MediaType=SPOST_PATH(1)` 与 `CopyStyle=SP_COPY_DELETESOURCE(1)` 数值相同。若将两者混淆，会导致**源文件被删除**。
*   **Rule:** 必须严格对照 API 签名，**分离**不同参数的变量。严禁将不同参数的 Flag 混合在一个变量中。

---

## **指令十四：库实例与全局 C 空间分离 (Library vs ffi.C)**

**Context:** `ffi.load` 和 `ffi.cdef` 的作用域是完全隔离的。

### **1. 访问常量/枚举/结构体 (Accessing Types/Consts)**
*   **机制:** `ffi.cdef` 中定义的所有内容（`static const`, `enum`, `typedef`, `struct`）都属于 **LuaJIT 全局 C 命名空间**。
*   **❌ 错误:** `local lib = ffi.load("mylib"); local val = lib.MY_CONST`。`lib` userdata 仅包含导出函数，不包含 cdef 定义的常量。
*   **✅ 正确:** `local C = ffi.C; local val = C.MY_CONST`。

### **2. 访问导出函数 (Accessing Functions)**
*   **机制:** 动态库导出函数（如 `CreateFileW`）必须通过 `ffi.load` 返回的实例调用。
*   **Rule:** 函数调用 `lib.Func()`，常量访问 `ffi.C.CONST`。

---

## **指令十五：原子化与全量交付协议 (Atomic Delivery)**

**Context:** 之前的错误往往源于“只修改片段”导致的上下文丢失（例如忘记 `require`，或者修改了 `cdef` 但未更新调用逻辑）。

### **1. 禁止省略号 (No Ellipsis Policy)**
*   **Rule:** 在生成代码时，**严禁**使用 `...`、`// ... same as before ...` 等省略符。
*   **Rationale:** 任何省略都会导致上下文断裂，使得代码无法直接运行或测试。必须输出**完整、可运行**的文件内容。

### **2. 依赖一致性检查 (Dependency Consistency)**
*   **Rule:** 修改任何文件（如 `ffi/newdev.lua`）时，必须同时检查并输出所有依赖该文件的上层模块（如 `driver.lua`）。
*   **Rationale:** FFI 绑定的变更通常伴随着调用逻辑的变更。孤立的修改是 Bug 之源。

### **3. 单一文件完整性 (Single Source of Truth)**
*   **Rule:** 每次输出必须包含完整的 `require` 头和 `return` 尾。不要假设用户知道上下文。