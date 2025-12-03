local ffi = require 'ffi'
local bit = require 'bit'
local ntext = require 'ffi.req' 'Windows.sdk.ntext'
local ntdll = require 'ffi.req' 'Windows.sdk.ntdll' -- for NtSetInformationFile basics
local kernel32 = require 'ffi.req' 'Windows.sdk.kernel32'
local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local util = require 'win-utils.util'
local Handle = require 'win-utils.handle'
local token = require 'win-utils.process.token'

local M = {}
local C = ffi.C

-- 在 advapi32 中补充 ConvertStringSidToSidW 定义 (如果尚未存在)
ffi.cdef [[
    BOOL ConvertStringSidToSidW(LPCWSTR StringSid, PSID* Sid);
]]

-- 辅助：安全打开文件句柄用于 Native 操作
-- 使用 FILE_FLAG_BACKUP_SEMANTICS 以支持目录操作
local function open_file_native(path, access)
    local flags = bit.bor(C.FILE_FLAG_BACKUP_SEMANTICS, C.OPEN_EXISTING)
    local share = bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE)
    
    local hFile = kernel32.CreateFileW(util.to_wide(path), access, share, nil, C.OPEN_EXISTING, C.FILE_FLAG_BACKUP_SEMANTICS, nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return nil, util.format_error() end
    return Handle.guard(hFile)
end

-- 修改文件时间 (对应 PECMD SITE 命令)
-- 参数为 Windows FILETIME 格式 (INT64)。传入 nil 或 0 表示保持原样。
-- @param path: 文件路径
-- @param ctime: 创建时间
-- @param atime: 访问时间
-- @param wtime: 修改时间
function M.set_times(path, ctime, atime, wtime)
    -- 需要 FILE_WRITE_ATTRIBUTES 权限 (包含在 GENERIC_WRITE 中)
    local hFile, err = open_file_native(path, C.GENERIC_WRITE)
    if not hFile then return false, err end
    
    local info = ffi.new("FILE_BASIC_INFORMATION")
    
    -- 0 = Keep (保持原样), -1 = Disable Update
    info.CreationTime.QuadPart   = ctime or 0
    info.LastAccessTime.QuadPart = atime or 0
    info.LastWriteTime.QuadPart  = wtime or 0
    info.ChangeTime.QuadPart     = 0
    info.FileAttributes          = 0 -- 0 = Keep attributes
    
    local iosb = ffi.new("IO_STATUS_BLOCK")
    
    -- 使用 ntext 中定义的 NtSetInformationFile (如果 ntdll.lua 未绑定) 或 ntdll 的
    -- 注意：ntdll.lua 通常已绑定 NtSetInformationFile。
    local status = ntdll.NtSetInformationFile(hFile, iosb, info, ffi.sizeof(info), ntext.C.FileBasicInformation)
    
    Handle.close(hFile)
    
    if status < 0 then 
        return false, string.format("NtSetInformationFile failed: 0x%X", status) 
    end
    return true
end

-- 修改文件属性
-- @param attr_mask: 属性掩码 (e.g. FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)
function M.set_attributes(path, attr_mask)
    local hFile, err = open_file_native(path, C.GENERIC_WRITE)
    if not hFile then return false, err end
    
    local info = ffi.new("FILE_BASIC_INFORMATION")
    info.FileAttributes = attr_mask
    -- 时间字段设为 0 表示保持原样
    
    local iosb = ffi.new("IO_STATUS_BLOCK")
    local status = ntdll.NtSetInformationFile(hFile, iosb, info, ffi.sizeof(info), ntext.C.FileBasicInformation)
    
    Handle.close(hFile)
    if status < 0 then return false, string.format("0x%X", status) end
    return true
end

-- 强力删除 (Native Delete with POSIX Semantics)
-- 对应 PECMD FILE -force
-- 允许删除"正在使用"的文件（在句柄关闭后消失，且允许重命名/移动）
function M.force_delete(path)
    -- 1. 打开文件 (需 DELETE 权限)
    local hFile = kernel32.CreateFileW(util.to_wide(path), 
        0x00010000, -- DELETE
        bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE), 
        nil, 
        C.OPEN_EXISTING, 
        C.FILE_FLAG_BACKUP_SEMANTICS, -- 支持目录
        nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, util.format_error() end
    hFile = Handle.guard(hFile)
    
    local iosb = ffi.new("IO_STATUS_BLOCK")
    local status
    
    -- 2. 尝试 Win10+ DispositionEx (POSIX Semantics)
    -- POSIX 语义允许在文件打开时将其解除链接(Unlink)，文件将在最后一个句柄关闭时立即消失。
    local info_ex = ffi.new("FILE_DISPOSITION_INFO_EX") -- kernel32.lua 中已定义此结构
    info_ex.Flags = bit.bor(
        ntext.C.FILE_DISPOSITION_DELETE,
        ntext.C.FILE_DISPOSITION_POSIX_SEMANTICS,
        ntext.C.FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE
    )
    
    -- 注意：FileDispositionInformationEx = 64
    status = ntdll.NtSetInformationFile(hFile, iosb, info_ex, ffi.sizeof(info_ex), ntext.C.FileDispositionInformationEx)
    
    -- 3. 如果失败 (例如旧版系统)，回退到标准删除
    if status < 0 then
        local info = ffi.new("FILE_DISPOSITION_INFORMATION") -- ntext defined
        info.DeleteFile = 1
        status = ntdll.NtSetInformationFile(hFile, iosb, info, ffi.sizeof(info), ntext.C.FileDispositionInformation)
    end
    
    Handle.close(hFile)
    
    if status < 0 then 
        return false, string.format("Delete failed: 0x%X", status) 
    end
    return true
end

-- 获取文件所有权 (Take Ownership)
-- 将文件所有者强制设为 Administrators 组
-- 需要提升权限
function M.take_ownership(path)
    -- 1. 启用必要的特权
    token.enable_privilege("SeTakeOwnershipPrivilege")
    token.enable_privilege("SeRestorePrivilege")
    
    -- 2. 打开文件 (需 WRITE_OWNER 权限)
    local hFile = kernel32.CreateFileW(util.to_wide(path), 
        0x00080000, -- WRITE_OWNER
        bit.bor(C.FILE_SHARE_READ, C.FILE_SHARE_WRITE, C.FILE_SHARE_DELETE), 
        nil, 
        C.OPEN_EXISTING, 
        C.FILE_FLAG_BACKUP_SEMANTICS, 
        nil)
        
    if hFile == ffi.cast("HANDLE", -1) then return false, "Open failed: " .. util.format_error() end
    hFile = Handle.guard(hFile)
    
    -- 3. 创建 Administrators SID (S-1-5-32-544)
    local pSid = ffi.new("PSID[1]")
    local w_sid_str = util.to_wide("S-1-5-32-544")
    
    if advapi32.ConvertStringSidToSidW(w_sid_str, pSid) == 0 then
         Handle.close(hFile)
         return false, "Create SID failed"
    end
    
    local admin_sid = pSid[0]
    
    -- 4. 创建 Security Descriptor
    -- 使用足够大的缓冲区
    local sd_buf = ffi.new("uint8_t[256]") 
    local sd = ffi.cast("PSECURITY_DESCRIPTOR", sd_buf)
    
    -- SECURITY_DESCRIPTOR_REVISION = 1
    if ntext.RtlCreateSecurityDescriptor(sd, 1) < 0 then
        kernel32.LocalFree(admin_sid)
        Handle.close(hFile)
        return false, "Create SD failed"
    end
    
    if ntext.RtlSetOwnerSecurityDescriptor(sd, admin_sid, 0) < 0 then
        kernel32.LocalFree(admin_sid)
        Handle.close(hFile)
        return false, "Set Owner SD failed"
    end
    
    -- 5. 应用所有者变更
    local status = ntext.NtSetSecurityObject(hFile, ntext.C.OWNER_SECURITY_INFORMATION, sd)
    
    kernel32.LocalFree(admin_sid)
    Handle.close(hFile)
    
    if status < 0 then 
        return false, string.format("NtSetSecurityObject failed: 0x%X", status) 
    end
    return true
end

return M