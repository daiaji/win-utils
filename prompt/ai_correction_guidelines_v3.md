# **System Protocol: LuaJIT FFI & C++ Interop Core Guidelines**

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
    *   **Rule:** 项目文档（`docs/*.md`）和代码注释是唯一真理。如果文档规定了特定的 API 模式（如自定义的内存分配器或任务系统），**必须** 遵循文档，覆盖通用训练数据。
2.  **🚧 Syntax Guard:** "代码中是否存在 Lua 5.3+ 符号 (`|`, `//`, `_ENV`) 或 C 代码中的 Lua 注释 (`--`) ？"
    *   **Rule:** 必须拦截所有不兼容语法，并自动转换为 LuaJIT 兼容写法。
3.  **🔗 Contract Sync:** "我是否修改了 Lua/C++ 边界的一侧？"
    *   **Rule:** 如果 Lua 端新增/修改了 `native.call`，**必须** 提示或生成 C++ 端对应的处理逻辑。严禁只修改一端导致契约断裂。
4.  **🛡️ ABI Guard:** "C API 调用是否严格遵守 Lua 5.1 标准？"
    *   **Rule:** 严禁使用 5.2+ API (如 `lua_setuservalue`)，`lua_resume` 只能传 2 个参数。
5.  **💾 Memory Guard:** "异步传输的指针是否在 Lua 端被锚定（Anchored）？"
    *   **Rule:** 防止 GC 在 C++ 使用数据前回收内存，必须显式持有引用。

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

## **指令四：内存安全与逻辑防御**

### **1. 强制区分数组索引 (Schizophrenia Indexing)**
*   **Lua Table:** Index starts at **1**.
*   **FFI Pointer/Array:** Index starts at **0**.

### **2. FFI 锚定 (Anchoring)**
**Rule:** 传递给 C 的异步/长期指针，必须在 Lua 端锚定，否则 GC 会销毁它导致 Crash。
```lua
local anchors = {} -- 模块级锚点表
function M.reg(id)
    local obj = ffi.new("Struct", id)
    table.insert(anchors, obj) -- ✅ Prevent GC
    C.AsyncOp(obj)
end
```

### **3. 审慎评估封装意图 (Wrapper Preservation)**
**Rule:** 在重构代码时，严禁盲目移除 Lua 封装函数。
*   **❌ 危险移除:** 如果封装函数包含 `if ret == 0` (错误检查)、`ffi.gc` (资源释放) 或 `or default_val` (默认值)，移除它会导致逻辑崩坏。
*   **✅ 安全移除:** 仅当函数是纯转发 (`M.func = C.func`) 时，才可建议移除。

### **4. 真值陷阱**
**Rule:** C 返回的 `0` 在 Lua 中是 `true`。
*   ❌ `if C.Func() then` (0 也会进入分支)
*   ✅ `if C.Func() ~= 0 then`

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

**Context:** Lua 和 C++ 通过字符串 key 或 ID 进行通信。
**Rule:** 当你生成或修改代码时，**必须** 检查另一端：
1.  **Lua -> C++:** 如果在 Lua 增加了 `native.call("ScanNetwork")`，必须检查或生成 C++ 端的 `if (strcmp(cmd, "ScanNetwork") == 0)` 分支。
2.  **C++ -> Lua:** 如果 C++ 修改了回调函数的参数个数，必须同步更新 Lua 端的回调签名。

---

## **指令七：代码完整性与版本控制协议 (Integrity & Git Hygiene)**

**Context:** 为了维护 Git 提交历史的清晰度（Clean Git Diff），并确保质量体系不降级，**必须** 遵循以下输出约束。

### **1. 风格与注释零侵入 (Style & Comment Preservation)**
*   **Rule:** 在生成或修改代码时，请务必严格遵循原始代码的风格与格式（缩进、空格、换行位置）。
*   **Rule:** **严格保留原有注释**。禁止删除任何现有的注释，除非该代码块被彻底重写且注释已失效。

### **2. 测试覆盖率铁律 (Test Coverage Guarantee)**
*   **Rule:** 对于单元测试、集成测试，**不要以任何理由缩减测试的覆盖面和测试项目**。
*   **Rule:** 如果修改了功能代码，必须同步修正断言（Asserts），而不是注释掉测试用例。