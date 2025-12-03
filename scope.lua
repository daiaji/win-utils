local M = {}

function M.using(res, func)
    local ok, ret1, ret2, ret3 = xpcall(function() 
        return func(res) 
    end, debug.traceback)
    
    if res then
        if type(res.close) == "function" then
            res:close()
        elseif type(res.free) == "function" then
            res:free()
        end
    end
    
    if not ok then error(ret1) end
    return ret1, ret2, ret3
end

return M