local ffi = require 'ffi'
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local util = require 'win-utils.util'

local M = {}
local C = ffi.C

function M.burn_dd(image_path, drive, progress_cb)
    -- GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING
    local hFile = kernel32.CreateFileW(util.to_wide(image_path), C.GENERIC_READ, C.FILE_SHARE_READ, nil, C.OPEN_EXISTING, 0, nil)
    if hFile == ffi.cast("HANDLE", -1) then return false, "Open Image Failed" end

    local file_size = ffi.new("LARGE_INTEGER")
    kernel32.GetFileSizeEx(hFile, file_size)
    local total = tonumber(file_size.QuadPart)

    local chunk_size = 1024 * 1024 
    local buffer = ffi.new("uint8_t[?]", chunk_size)
    local read_bytes = ffi.new("DWORD[1]")
    local processed = 0
    local success = true
    local err = nil

    while processed < total do
        if kernel32.ReadFile(hFile, buffer, chunk_size, read_bytes, nil) == 0 then
            success = false; err = "Read Error"; break
        end
        if read_bytes[0] == 0 then break end

        local data_str = ffi.string(buffer, read_bytes[0])
        
        local padding = 0
        if #data_str % drive.sector_size ~= 0 then
            padding = drive.sector_size - (#data_str % drive.sector_size)
            data_str = data_str .. string.rep("\0", padding)
        end

        if not drive:write_sectors(processed, data_str) then
            success = false; err = "Write Error"; break
        end

        processed = processed + read_bytes[0]
        if progress_cb then
            if not progress_cb(processed / total) then
                success = false; err = "Aborted"; break
            end
        end
    end

    kernel32.CloseHandle(hFile)
    return success, err
end

return M