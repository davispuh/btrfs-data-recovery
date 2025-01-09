
module Btrfs
    module Constants

        SUPERBLOCK_OFFSETS = [0x10000, 0x4000000, 0x4000000000]
        SUPERBLOCK_SIZE = 0x1000
        SUPERBLOCK_MAGIC = '_BHRfS_M'

        SECTOR_SIZE = 4096
        BLOCK_SIZE = 16384
        UUID_SIZE = 16

        KEY_SIZE = 17
        LEAF_ITEM_SIZE = KEY_SIZE + 4 + 4
        NODE_ITEM_SIZE = KEY_SIZE + 8 + 8

        HEADER_SIZE = 101

        MAX_ITEMS = (BLOCK_SIZE - HEADER_SIZE) / NODE_ITEM_SIZE

        NUM_BACKUP_ROOTS = 4

        CSUM_TYPE_CRC32  = 0
        CSUM_TYPE_XXHASH = 1
        CSUM_TYPE_SHA256 = 2
        CSUM_TYPE_BLAKE2 = 3

        CSUM_NAMES = %w[crc32c xxhash sha256 blake2]
        CSUM_LENGTHS = [4, 8, 16, 16]

        DEV_STATS_OBJECTID       = 0
        ROOT_TREE_OBJECTID       = 1
        EXTENT_TREE_OBJECTID     = 2
        CHUNK_TREE_OBJECTID      = 3
        DEV_TREE_OBJECTID        = 4
        FS_TREE_OBJECTID         = 5
        ROOT_TREE_DIR_OBJECTID   = 6
        CSUM_TREE_OBJECTID       = 7
        QUOTA_TREE_OBJECTID      = 8
        UUID_TREE_OBJECTID       = 9
        FREE_SPACE_TREE_OBJECTID = 10

        BALANCE_OBJECTID         = -4
        ORPHAN_OBJECTID          = -5
        TREE_LOG_OBJECTID        = -6
        TREE_LOG_FIXUP_OBJECTID  = -7
        TREE_RELOC_OBJECTID      = -8
        DATA_RELOC_TREE_OBJECTID = -9
        EXTENT_CSUM_OBJECTID     = -10
        FREE_SPACE_OBJECTID      = -11
        FREE_INO_OBJECTID        = -12
        MIN_VALID_OBJECTID       = FREE_INO_OBJECTID

        TREE_NAMES = %w[
            DEV_STATS
            ROOT_TREE
            EXTENT_TREE
            CHUNK_TREE
            DEV_TREE
            FS_TREE
            ROOT_TREE_DIR
            CSUM_TREE
            QUOTA_TREE
            UUID_TREE
            FREE_SPACE_TREE

            UNKNOWN

            FREE_INO
            FREE_SPACE
            EXTENT_CSUM
            DATA_RELOC_TREE
            TREE_RELOC
            TREE_LOG_FIXUP
            TREE_LOG
            ORPHAN
            BALANCE
            UNKNOWN
            UNKNOWN
            UNKNOWN
        ]

        UNTYPED           = 0
        INODE_ITEM        = 1
        INODE_REF         = 12
        INODE_EXTREF      = 13
        XATTR_ITEM        = 24
        VERITY_DESC_ITEM  = 36
        ORPHAN_ITEM       = 48
        DIR_LOG_ITEM      = 60
        DIR_LOG_INDEX     = 72
        DIR_ITEM          = 84
        DIR_INDEX         = 96
        EXTENT_DATA       = 108
        EXTENT_CSUM       = 128
        ROOT_ITEM         = 132
        ROOT_BACKREF      = 144
        ROOT_REF          = 156
        EXTENT_ITEM       = 168
        METADATA_ITEM     = 169
        TREE_BLOCK_REF    = 176
        EXTENT_DATA_REF   = 178
        EXTENT_REF_V0     = 180
        SHARED_BLOCK_REF  = 182
        SHARED_DATA_REF   = 184
        BLOCK_GROUP_ITEM  = 192
        FREE_SPACE_INFO   = 198
        FREE_SPACE_EXTENT = 199
        FREE_SPACE_BITMAP = 200
        DEV_EXTENT        = 204
        DEV_ITEM          = 216
        CHUNK_ITEM        = 228
        QGROUP_STATUS     = 240
        QGROUP_INFO       = 242
        QGROUP_LIMIT      = 244
        QGROUP_RELATION   = 246
        TEMPORARY_ITEM    = 248
        PERSISTENT_ITEM   = 249
        DEV_REPLACE       = 250
        UUID_KEY_SUBVOL   = 251
        UUID_KEY_RECEIVED_SUBVOL = 252
        STRING_ITEM       = 253


        EXTENT_FLAG_DATA = 0x1
        EXTENT_FLAG_TREE_BLOCK = 0x2
        BLOCK_FLAG_FULL_BACKREF = 0x80
    end
end
