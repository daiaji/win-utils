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
    LINUX_ENCRYPTED             = "{7FFEC5C9-2D00-49B7-8941-3EA10A5586B7}",
    LINUX_LUKS                  = "{CA7D7CCB-63ED-4C53-861C-1742536059CC}",
    LINUX_RESERVED              = "{8DA63339-0007-60C0-C436-083AC8230908}",
    LINUX_ROOT_X86              = "{44479540-F297-41B2-9AF7-D131D5F0458A}",
    LINUX_ROOT_X86_64           = "{4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709}",
    LINUX_ROOT_ARM              = "{69DAD710-2CE4-4E3C-B16C-21A1D49ABED3}",
    LINUX_ROOT_ARM64            = "{B921B045-1DF0-41C3-AF44-4C6F280D3FAE}",

    -- Android
    ANDROID_BOOT                = "{49A4D17F-93A3-45C1-A0DE-F50B2EBE2599}",
    ANDROID_RECOVERY            = "{4177C722-9E92-4AAB-8644-43502BFD5506}",
    ANDROID_SYSTEM              = "{38F428E6-D326-425D-9140-6E0EA133647C}",
    ANDROID_DATA                = "{DC76DDA9-5AC1-491C-AF42-A82591580C0D}",
    ANDROID_CACHE               = "{A893EF21-E428-470A-9E55-0668FD91A2D9}",
    ANDROID_MISC                = "{EF32A33B-A409-486C-9141-9FFB711F6266}",
    ANDROID_METADATA            = "{20AC26BE-20B7-11E3-84C5-6CFDB94711E9}",
    
    -- ChromeOS
    CHROMEOS_KERNEL             = "{FE3A2A5D-4F32-41A7-B725-ACCC3285A309}",
    CHROMEOS_ROOT               = "{3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC}",
    CHROMEOS_RESERVED           = "{2E0A753D-9E48-43B0-8337-B15192CB1B5E}",

    -- Apple
    APPLE_HFS                   = "{48465300-0000-11AA-AA11-00306543ECAC}",
    APPLE_APFS                  = "{7C3457EF-0000-11AA-AA11-00306543ECAC}",
    APPLE_UFS                   = "{55465300-0000-11AA-AA11-00306543ECAC}",
    APPLE_ZFS                   = "{6A898CC3-1DD2-11B2-99A6-080020736631}",
    APPLE_RAID                  = "{52414944-0000-11AA-AA11-00306543ECAC}",
    APPLE_RAID_OFFLINE          = "{52414944-5F4F-11AA-AA11-00306543ECAC}",
    APPLE_BOOT                  = "{426F6F74-0000-11AA-AA11-00306543ECAC}",
    APPLE_LABEL                 = "{4C616265-6C00-11AA-AA11-00306543ECAC}",
    APPLE_RECOVERY              = "{5265636F-7665-11AA-AA11-00306543ECAC}",
    APPLE_CORE_STORAGE          = "{53746F72-6167-11AA-AA11-00306543ECAC}",

    -- FreeBSD
    FREEBSD_BOOT                = "{83BD6B9D-7F41-11DC-BE0B-001560B84F0F}",
    FREEBSD_DATA                = "{516E7CB4-6ECF-11D6-8FF8-00022D09712B}",
    FREEBSD_SWAP                = "{516E7CB5-6ECF-11D6-8FF8-00022D09712B}",
    FREEBSD_UFS                 = "{516E7CB6-6ECF-11D6-8FF8-00022D09712B}",
    FREEBSD_VINUM               = "{516E7CB8-6ECF-11D6-8FF8-00022D09712B}",
    FREEBSD_ZFS                 = "{516E7CBA-6ECF-11D6-8FF8-00022D09712B}",

    -- VMware
    VMWARE_VMFS                 = "{AA31E02A-400F-11DB-9590-000C2911D1B8}",
    VMWARE_RESERVED             = "{9198EFFC-31C0-11DB-8F78-000C2911D1B8}",
    VMWARE_KCORE                = "{9D275380-40AD-11DB-BF97-000C2911D1B8}",

    -- General
    BIOS_BOOT                   = "{21686148-6449-6E6F-744E-656564454649}", -- BIOS Boot Partition (GRUB)
    UNUSED                      = "{00000000-0000-0000-0000-000000000000}",

    -- Data Attributes (Bitmask)
    -- [CHANGED] Use ULL suffix to prevent precision loss in Lua numbers (doubles).
    -- Standard Lua numbers only maintain 53 bits of integer precision.
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
    XENIX_ROOT  = 0x02,
    XENIX_USR   = 0x03,
    FAT16_SMALL = 0x04,
    EXTENDED    = 0x05,
    FAT16       = 0x06,
    NTFS        = 0x07, -- Also exFAT, IFS
    AIX         = 0x08,
    AIX_BOOT    = 0x09,
    OS2_BOOT    = 0x0A,
    FAT32       = 0x0B,
    FAT32_LBA   = 0x0C,
    FAT16_LBA   = 0x0E,
    EXTENDED_LBA= 0x0F,
    OPUS        = 0x10,
    HIDDEN_FAT12= 0x11,
    COMPAQ_DIAG = 0x12,
    HIDDEN_FAT16_S=0x14,
    HIDDEN_FAT16= 0x16,
    HIDDEN_NTFS = 0x17,
    HIDDEN_FAT32= 0x1B,
    HIDDEN_FAT32_L=0x1C,
    HIDDEN_FAT16_L=0x1E,
    WIN_RECOVERY= 0x27, -- Hidden NTFS WinRE
    PLAN9       = 0x39,
    PMAGIC      = 0x3C,
    QNX4        = 0x4D,
    QNX4_2      = 0x4E,
    QNX4_3      = 0x4F,
    DM          = 0x50,
    DM6         = 0x51,
    EZ_DRIVE    = 0x55,
    SPEEDSTOR   = 0x61,
    GNU_HURD    = 0x63,
    NETWARE_286 = 0x64,
    NETWARE_386 = 0x65,
    LINUX_SWAP  = 0x82,
    LINUX       = 0x83,
    HIBERNATION = 0x84,
    LINUX_EXT   = 0x85,
    NTFS_VOL_SET= 0x86,
    NTFS_VOL_SET2=0x87,
    LINUX_LVM   = 0x8E,
    AMOEBA      = 0x93,
    AMOEBA_BBT  = 0x94,
    BSD_OS      = 0x9F,
    IBM_THINKPAD= 0xA0,
    FREEBSD     = 0xA5,
    OPENBSD     = 0xA6,
    NEXTSTEP    = 0xA7,
    DARWIN_UFS  = 0xA8,
    NETBSD      = 0xA9,
    DARWIN_BOOT = 0xAB,
    HFS         = 0xAF, -- HFS/HFS+
    BSDI        = 0xB7,
    BSDI_SWAP   = 0xB8,
    SOLARIS_BOOT= 0xBE,
    SOLARIS     = 0xBF,
    DRDOS_FAT12 = 0xC1,
    DRDOS_FAT16 = 0xC4,
    DRDOS_FAT16_L=0xC6,
    SYRINX      = 0xC7,
    NON_FS_DATA = 0xDA,
    CP_M        = 0xDB,
    DELL_UTIL   = 0xDE,
    BOOTIT      = 0xDF,
    DOS_ACCESS  = 0xE1,
    DOS_RO      = 0xE3,
    SPEEDSTOR_L = 0xE4,
    RUFUS_EXTRA = 0xEA,
    BEOS        = 0xEB,
    EFI_GPT_PROT= 0xEE, -- Protective MBR
    ESP         = 0xEF, -- EFI System Partition
    LINUX_RAID  = 0xFD,
    LANSTEP     = 0xFE,
    XENIX_BBT   = 0xFF
}

return M