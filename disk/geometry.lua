local M = {}

-- [Pure Logic] 对齐辅助函数
-- 无需系统调用，无错误上下文
function M.align(v, a) 
    return math.ceil(v/a)*a 
end

return M