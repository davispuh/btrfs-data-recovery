module btrfs.superblock;

import std.stdint : uint8_t, uint32_t, uint64_t;
import std.algorithm.searching : canFind;
import btrfs.io : loadable;
import btrfs.utils : createGetters, getterMixin, isScalarType, isArray, littleEndianToNative;
import btrfs.header : FSID_SIZE, UUID_SIZE;
import btrfs.checksum : CSUM_SIZE, ChecksumType, calculateChecksum;
import btrfs.items : Key, Chunk, ChunkItem, StripeItem;

const SUPERBLOCK_OFFSETS = [0x10000uL, 0x4000000uL, 0x4000000000uL];
const SUPERBLOCK_SIZE = 0x1000;
const SUPERBLOCK_MAGIC = "_BHRfS_M";

const MAGIC_SIZE = SUPERBLOCK_MAGIC.length;
const LABEL_SIZE = 256;
const SYSTEM_CHUNK_ARRAY_SIZE = 2048;
const NUM_BACKUP_ROOTS = 4;

struct DevItem
{
    align(1):

    uint64_t devid;
    uint64_t totalBytes;
    uint64_t bytesUsed;
    uint32_t ioAlign;
    uint32_t ioWidth;
    uint32_t sectorSize;
    uint64_t type;
    uint64_t generation;
    uint64_t startOffset;
    uint32_t devGroup;
    uint8_t seekSpeed;
    uint8_t bandwidth;
    uint8_t[UUID_SIZE] uuid;
    uint8_t[UUID_SIZE] fsid;
}

struct RootBackup
{
    align(1):

    uint64_t treeRoot;
    uint64_t treeRootGen;

    uint64_t chunkRoot;
    uint64_t chunkRootGen;

    uint64_t extentRoot;
    uint64_t extentRootGen;

    uint64_t fsRoot;
    uint64_t fsRootGen;

    uint64_t devRoot;
    uint64_t devRootGen;

    uint64_t csumRoot;
    uint64_t csumRootGen;

    uint64_t totalBytes;
    uint64_t bytesUsed;
    uint64_t numNevices;

    uint64_t[4] unused64;

    uint8_t treeRootLevel;
    uint8_t chunkRootLevel;
    uint8_t extentRootLevel;
    uint8_t fsRootLevel;
    uint8_t devRootLevel;
    uint8_t csumRootLevel;
    uint8_t[10] unused8;
}

struct SuperblockData
{
    align(1):

    uint8_t[CSUM_SIZE] csum;
    uint8_t[FSID_SIZE] fsid;
    uint64_t bytenr;
    uint64_t flags;
    char[MAGIC_SIZE] magic;
    uint64_t generation;

    uint64_t root;
    uint64_t chunkRoot;
    uint64_t logRoot;
    uint64_t logRootTransId;

    uint64_t totalBytes;
    uint64_t bytesUsed;

    uint64_t rootDirObjectId;
    uint64_t numDevices;

    uint32_t sectorsize;
    uint32_t nodesize;
    uint32_t unusedLeafsize;
    uint32_t stripesize;

    uint32_t sysChunkArraySize;
    uint64_t chunkRootGeneration;

    uint64_t compatFlags;
    uint64_t compatRoFlags;
    uint64_t incompatFlags;

    ChecksumType csumType;

    uint8_t rootLevel;
    uint8_t chunkRootLevel;
    uint8_t logRootLevel;
    DevItem devItem;

    char[LABEL_SIZE] label;

    uint64_t cacheGeneration;
    uint64_t uuidTreeGeneration;

    uint8_t[FSID_SIZE] metadataUUID;
    uint64_t[28] reserved;

    uint8_t[SYSTEM_CHUNK_ARRAY_SIZE] sysChunkArray;
    RootBackup[NUM_BACKUP_ROOTS] superRoots;
}


struct Superblock
{
    mixin loadable;
    mixin createGetters!(typeof(*this.data));

    @property @nogc const(DevItem*) devItem() const pure nothrow return
    {
        return cast(const DevItem*)(this.buffer + this.data.devItem.offsetof);
    }

    bool process(shared const void* buffer, void delegate(ref const typeof(this) block) action)
    {
        this.load(buffer);
        if (this.matches())
        {
            action(this);
            return true;
        }
        return false;
    }

    @nogc const bool matches() pure nothrow
    {
        if (this.magic != SUPERBLOCK_MAGIC)
        {
            return false;
        }

        return true;
    }

    bool isValid() const nothrow
    {
        auto checksum = calculateChecksum(this.buffer[typeof(*this.data).csum.sizeof..SUPERBLOCK_SIZE], this.csumType);
        if (this.csum != checksum) {
            return false;
        }

        return true;
    }

    const(Chunk[]) getSystemChunks() const
    {
        Chunk[] chunks;
        const(ubyte)* ptr = this.buffer + SuperblockData.sysChunkArray.offsetof;
        auto end = ptr + this.sysChunkArraySize;
        while (ptr < end)
        {
            Chunk chunk;
            chunk.key = cast(const(Key)*)ptr;
            ptr += Key.sizeof;
            chunk.item = cast(const(ChunkItem)*)ptr;
            chunks ~= chunk;
            ptr += ChunkItem.sizeof + StripeItem.sizeof * chunks[$ - 1].numStripes;
        }
        return chunks;
    }

private:
    union
    {
        immutable(ubyte) *buffer;
        immutable(SuperblockData) *data;
    }
}

bool loadSuperblock(ref Superblock superblock, shared const void[] buffer) // nothrow
{
    foreach (offset; SUPERBLOCK_OFFSETS)
    {
        if (offset + SUPERBLOCK_SIZE < buffer.length)
        {
            superblock.load(buffer.ptr + offset);

            if (!superblock.matches())
            {
                return false;
            }
            return superblock.isValid();
        }
    }
    return false;
}

@nogc @safe bool isSuperblockOffset(const size_t offset) nothrow
{
    return SUPERBLOCK_OFFSETS.canFind(offset);
}
