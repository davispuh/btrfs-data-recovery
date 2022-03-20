module btrfs.header;

import std.stdint : uint8_t, uint32_t, int64_t, uint64_t;
import btrfs.checksum : CSUM_SIZE;

const FSID_SIZE = 16;
const UUID_SIZE = 16;

struct HeaderData
{
    align(1):

    uint8_t[CSUM_SIZE] csum;
    uint8_t[FSID_SIZE] fsid;
    uint64_t bytenr;
    uint64_t flags;

    uint8_t[UUID_SIZE] chunkTreeUuid;
    uint64_t generation;
    ObjectID owner;
    uint32_t nritems;
    uint8_t level;

    @nogc const bool isLeaf() pure nothrow return
    {
        return this.level == 0;
    }

    @nogc const bool isNode() pure nothrow return
    {
        return !this.isLeaf();
    }
}

enum ObjectID : int64_t
{
    INVALID       = -32000,

    DEV_STATS       = 0,
    ROOT_TREE       = 1,
    EXTENT_TREE     = 2,
    CHUNK_TREE      = 3,
    DEV_TREE        = 4,
    FS_TREE         = 5,
    ROOT_TREE_DIR   = 6,
    CSUM_TREE       = 7,
    QUOTA_TREE      = 8,
    UUID_TREE       = 9,
    FREE_SPACE_TREE = 10,

    BALANCE_OBJECTID         = -4,
    ORPHAN_OBJECTID          = -5,
    TREE_LOG_OBJECTID        = -6,
    TREE_LOG_FIXUP_OBJECTID  = -7,
    TREE_RELOC_OBJECTID      = -8,
    DATA_RELOC_TREE_OBJECTID = -9,
    EXTENT_CSUM_OBJECTID     = -10,
    FREE_SPACE_OBJECTID      = -11,
    FREE_INO_OBJECTID        = -12
}
