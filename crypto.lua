local ffi = require 'ffi'
local bit = require 'bit'
local util = require 'win-utils.core.util'

local advapi32 = require 'ffi.req' 'Windows.sdk.advapi32'
local M = {}

local PROV_RSA_AES = 24
local CRYPT_VERIFYCONTEXT = 0xF0000000
local HP_HASHVAL = 0x0002
local ALG = {
    md5 = 0x00008003,
    sha1 = 0x00008004,
    sha256 = 0x0000800c,
    sha384 = 0x0000800d,
    sha512 = 0x0000800e,
}

local crc32_table
local function crc32_update(crc, data)
    if not crc32_table then
        crc32_table = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) ~= 0 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
                else c = bit.rshift(c, 1) end
            end
            crc32_table[i] = c
        end
    end

    crc = bit.bnot(crc or 0)
    for i = 1, #data do
        crc = bit.bxor(crc32_table[bit.band(bit.bxor(crc, data:byte(i)), 0xff)], bit.rshift(crc, 8))
    end
    return bit.bnot(crc)
end

local function to_hex(data)
    return (data:gsub('.', function(ch) return string.format('%02x', ch:byte()) end))
end

local function open_hash(alg)
    local prov = ffi.new('HCRYPTPROV[1]')
    if advapi32.CryptAcquireContextW(prov, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) == 0 then
        return nil, util.last_error('CryptAcquireContextW failed')
    end

    local hash = ffi.new('HCRYPTHASH[1]')
    if advapi32.CryptCreateHash(prov[0], ALG[alg], 0, 0, hash) == 0 then
        advapi32.CryptReleaseContext(prov[0], 0)
        return nil, util.last_error('CryptCreateHash failed')
    end
    return prov[0], hash[0]
end

local function finish_hash(prov, hash)
    local len = ffi.new('DWORD[1]')
    if advapi32.CryptGetHashParam(hash, HP_HASHVAL, nil, len, 0) == 0 then
        advapi32.CryptDestroyHash(hash)
        advapi32.CryptReleaseContext(prov, 0)
        return nil, util.last_error('CryptGetHashParam size failed')
    end

    local buf = ffi.new('uint8_t[?]', len[0])
    if advapi32.CryptGetHashParam(hash, HP_HASHVAL, buf, len, 0) == 0 then
        advapi32.CryptDestroyHash(hash)
        advapi32.CryptReleaseContext(prov, 0)
        return nil, util.last_error('CryptGetHashParam failed')
    end

    advapi32.CryptDestroyHash(hash)
    advapi32.CryptReleaseContext(prov, 0)
    return to_hex(ffi.string(buf, len[0]))
end

function M.hash(data, alg)
    alg = (alg or 'sha256'):lower()
    if alg == 'crc32' then return bit.tohex(crc32_update(0, data or '')) end
    if not ALG[alg] then return nil, 'Unsupported hash: ' .. tostring(alg) end

    local prov, hash_or_err = open_hash(alg)
    if not prov then return nil, hash_or_err end
    local hash = hash_or_err
    data = data or ''
    if #data > 0 and advapi32.CryptHashData(hash, ffi.cast('const BYTE*', data), #data, 0) == 0 then
        advapi32.CryptDestroyHash(hash)
        advapi32.CryptReleaseContext(prov, 0)
        return nil, util.last_error('CryptHashData failed')
    end
    return finish_hash(prov, hash)
end

function M.hash_file(path, alg)
    alg = (alg or 'sha256'):lower()
    local f, err = io.open(path, 'rb')
    if not f then return nil, err end

    if alg == 'crc32' then
        local crc = 0
        while true do
            local chunk = f:read(1024 * 1024)
            if not chunk then break end
            crc = crc32_update(crc, chunk)
        end
        f:close()
        return bit.tohex(crc)
    end

    if not ALG[alg] then f:close(); return nil, 'Unsupported hash: ' .. tostring(alg) end
    local prov, hash_or_err = open_hash(alg)
    if not prov then f:close(); return nil, hash_or_err end
    local hash = hash_or_err

    while true do
        local chunk = f:read(1024 * 1024)
        if not chunk then break end
        if advapi32.CryptHashData(hash, ffi.cast('const BYTE*', chunk), #chunk, 0) == 0 then
            f:close()
            advapi32.CryptDestroyHash(hash)
            advapi32.CryptReleaseContext(prov, 0)
            return nil, util.last_error('CryptHashData failed')
        end
    end
    f:close()
    return finish_hash(prov, hash)
end

return M
