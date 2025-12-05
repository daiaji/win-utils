local M = {}

M.GPT = {
    -- Windows
    BASIC_DATA                  = "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}",
    ESP                         = "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}",
    MSR                         = "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}",
    RECOVERY                    = "{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}",
    LDM_METADATA                = "{5808C8AA-7E8F-42E0-85D2-E1E90434CFB3}",
    LDM_DATA                    = "{AF9B60A0-1431-4F62-BC68-3311714A69AD}",
    STORAGE_SPACES              = "{E75CAF8F-F680-4CEE-AFA3-B001E56EFC2D}",

    -- Linux
    LINUX_DATA                  = "{0FC63DAF-8483-4772-8E79-3D69D8477DE4}",
    LINUX_RAID                  = "{A19D880F-05FC-4D3B-A006-743F0F84911E}",
    LINUX_SWAP                  = "{0657FD6D-A4AB-43C4-84E5-0933C84B4F4F}",
    LINUX_LVM                   = "{E6D6D379-F507-44C2-A23C-238F2A3DF928}",
    LINUX_HOME                  = "{933AC7E1-2EB4-4F13-B844-0E14E2AEF915}",
    LINUX_SRV                   = "{3B8F8425-20E0-4F3B-907F-1A25A76F98E8}",
    
    -- Apple
    APPLE_HFS                   = "{48465300-0000-11AA-AA11-00306543ECAC}",
    APPLE_APFS                  = "{7C3457EF-0000-11AA-AA11-00306543ECAC}",
    APPLE_RECOVERY              = "{5265636F-7665-11AA-AA11-00306543ECAC}",

    -- Android/ChromeOS
    ANDROID_DATA                = "{DC76DDA9-5AC1-491C-AF42-A82591580C0D}",
    CHROMEOS_KERNEL             = "{FE3A2A5D-4F32-41A7-B725-ACCC3285A309}",

    -- Data Attributes (Bitmask)
    FLAGS = {
        PLATFORM_REQUIRED       = 0x0000000000000001ULL,
        IGNORE                  = 0x0000000000000002ULL,
        LEGACY_BIOS_BOOT        = 0x0000000000000004ULL,
        READ_ONLY               = 0x1000000000000000ULL,
        HIDDEN                  = 0x4000000000000000ULL,
        NO_DRIVE_LETTER         = 0x8000000000000000ULL
    }
}

M.MBR = {
    EMPTY       = 0x00,
    FAT12       = 0x01,
    EXTENDED    = 0x05,
    FAT16       = 0x06,
    NTFS        = 0x07, -- Also exFAT, IFS
    FAT32       = 0x0B,
    FAT32_LBA   = 0x0C,
    FAT16_LBA   = 0x0E,
    EXTENDED_LBA= 0x0F,
    HIDDEN_NTFS = 0x17,
    WIN_RECOVERY= 0x27,
    LINUX_SWAP  = 0x82,
    LINUX       = 0x83,
    LINUX_EXT   = 0x85,
    LINUX_LVM   = 0x8E,
    HFS         = 0xAF,
    ESP         = 0xEF,
    LINUX_RAID  = 0xFD
}

return M