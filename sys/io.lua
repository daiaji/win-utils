local M = {}

-- [tee] Split Output to Console and File
-- @param path: 日志文件路径
-- @param append: 是否追加模式 (默认覆盖)
-- @return: 一个类似 file 的对象，支持 write/close
function M.tee(path, append)
    local mode = append and "a+" or "w"
    local f, err = io.open(path, mode)
    if not f then return nil, err end
    
    -- 立即设置文件缓冲模式为行缓冲或无缓冲，防止崩溃时日志丢失
    f:setvbuf("line")
    
    local tee_obj = {
        file = f,
        
        -- 核心：同时写入标准输出和文件
        write = function(self, ...)
            local args = {...}
            -- Lua 的 io.write 支持多个参数
            io.write(unpack(args))
            self.file:write(unpack(args))
            -- 强制刷新，确保实时性（类似 Coreutils 的行为）
            self.file:flush()
        end,
        
        -- 辅助：类似 print 的行为（自动加换行，参数转 string）
        print = function(self, ...)
            local args = {...}
            local parts = {}
            for i, v in ipairs(args) do parts[i] = tostring(v) end
            -- 使用 Tab 分隔，类似 print
            local line = table.concat(parts, "\t") .. "\n"
            
            io.write(line)
            self.file:write(line)
            self.file:flush()
        end,
        
        close = function(self)
            if self.file then
                self.file:close()
                self.file = nil
            end
        end
    }
    
    return tee_obj
end

return M