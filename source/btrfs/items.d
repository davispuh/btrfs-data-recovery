module btrfs.items;

import std.stdint : uint8_t, uint16_t, uint32_t, int64_t, uint64_t;
import std.typecons : BitFlags;
import std.bitmanip : nativeToLittleEndian;
import btrfs.header : UUID_SIZE;
import btrfs.utils : littleEndianToNative;

enum ItemType : uint8_t
{
    INODE_ITEM        = 1,
    INODE_REF         = 12,
    INODE_EXTREF      = 13,
    XATTR_ITEM        = 24,
    ORPHAN_ITEM       = 48,
    DIR_LOG_ITEM      = 60,
    DIR_LOG_INDEX     = 72,
    DIR_ITEM          = 84,
    DIR_INDEX         = 96,
    EXTENT_DATA       = 108,
    EXTENT_CSUM       = 128,
    ROOT_ITEM         = 132,
    BLOCK_GROUP_ITEM  = 192,
    DEV_EXTENT        = 204,
    DEV_ITEM          = 216,
    CHUNK_ITEM        = 228
}

enum BlockGroupType : uint64_t
{
    DATA     = 1 << 0,
    SYSTEM   = 1 << 1,
    METADATA = 1 << 2,

    RAID0    = 1 << 3,
    RAID1    = 1 << 4,
    DUP      = 1 << 5,
    RAID10   = 1 << 6,
    RAID5    = 1 << 7,
    RAID6    = 1 << 8,
    RAID1C3  = 1 << 9,
    RAID1C4  = 1 << 10,
}

alias ChunkType = BlockGroupType;

struct Key
{
    align(1):

    ubyte[8] _objectid;
    ItemType type;
    ubyte[8] _offset;

    @property @nogc const(int64_t) objectid() const pure nothrow
    {
        return littleEndianToNative!(int64_t)(this._objectid);
    }

    @property @nogc const(uint64_t) offset() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._offset);
    }

     @property ulong offset(ulong newOffset)
     {
        this._offset = nativeToLittleEndian(newOffset);
        return this.offset;
    }
}

struct NodeItem
{
    align(1):

public:
    Key key;

private:
    ubyte[8] _blockNumber;
    ubyte[8] _generation;

public:
    @property @nogc const(uint64_t) blockNumber() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._blockNumber);
    }

    @property @nogc const(uint64_t) generation() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._generation);
    }

}

struct LeafItem
{
    align(1):

public:
    Key key;

private:
    ubyte[4] _offset;
    ubyte[4] _size;

public:
    @property @nogc const(uint32_t) offset() const pure nothrow
    {
        return littleEndianToNative!(uint32_t)(this._offset);
    }

    @property @nogc const(uint32_t) size() const pure nothrow
    {
        return littleEndianToNative!(uint32_t)(this._size);
    }
}


struct Timespec
{
    align(1):

    uint64_t sec;
    uint32_t nsec;
}

struct InodeItem
{
    align(1):

    uint64_t generation;
    uint64_t transid;
    uint64_t size;
    uint64_t nbytes;
    uint64_t blockGroup;
    uint32_t nlink;
    uint32_t uid;
    uint32_t gid;
    uint32_t mode;
    uint64_t rdev;
    uint64_t flags;
    uint64_t sequence;
    uint64_t[4] reserved;
    Timespec atime;
    Timespec ctime;
    Timespec mtime;
    Timespec otime;
}

struct RootItem
{
    align(1):

    InodeItem inode;
    uint64_t generation;
    uint64_t rootDirid;
    ubyte[8] _bytenr;
    uint64_t byteLimit;
    uint64_t bytesUsed;
    uint64_t lastSnapshot;
    uint64_t flags;
    uint32_t refs;
    Key dropProgress;
    uint8_t dropLevel;
    uint8_t level;
    uint64_t generationV2;
    uint8_t[UUID_SIZE] uuid;
    uint8_t[UUID_SIZE] parentUuid;
    uint8_t[UUID_SIZE] receivedUuid;
    uint64_t ctransid;
    uint64_t otransid;
    uint64_t stransid;
    uint64_t rtransid;
    Timespec ctime;
    Timespec otime;
    Timespec stime;
    Timespec rtime;
    uint64_t[8] reserved;

    @property @nogc const(uint64_t) bytenr() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._bytenr);
    }

}


struct StripeItem
{
    align(1):

    ubyte[8] _devid;
    ubyte[8] _offset;
    uint8_t[UUID_SIZE] devUuid;

    @property @nogc const(uint64_t) devid() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._devid);
    }

    @property @nogc const(uint64_t) offset() const pure nothrow
    {
        return littleEndianToNative!(uint64_t)(this._offset);
    }
}

struct ChunkItem
{
    align(1):

    uint64_t length;
    uint64_t owner;
    uint64_t stripeLen;
    BitFlags!ChunkType type;

    uint32_t ioAlign;
    uint32_t ioWidth;

    uint32_t sectorSize;
    ubyte[2] _numStripes;
    ubyte[2] _subStripes;
    StripeItem[1] stripe;

    @property @nogc const(uint16_t) numStripes() const pure nothrow
    {
        return littleEndianToNative!(uint16_t)(this._numStripes);
    }

    @property @nogc const(uint16_t) subStripes() const pure nothrow
    {
        return littleEndianToNative!(uint16_t)(this._subStripes);
    }

    @property const(StripeItem[]) getStripes() const pure nothrow
    {
        StripeItem[] stripes;
        for (auto i = 0; i < this.numStripes; i++)
        {
            stripes ~= *(this.stripe.ptr + i);
        }
        return stripes;
    }
}

struct Chunk
{
    const(Key) *key;
    const(ChunkItem) *item;

    alias item this;

    bool isValid() const nothrow
    {
        if (this.key.type != ItemType.CHUNK_ITEM)
        {
            return false;
        }
        return true;
    }
}
