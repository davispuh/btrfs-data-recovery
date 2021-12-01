module btrfs.block;

import btrfs.io : loadable;
import btrfs.utils : createGetters, getterMixin, isScalarType, isArray, littleEndianToNative;
import btrfs.header : HeaderData;
import btrfs.items : NodeItem, LeafItem, RootItem, ChunkItem;
import btrfs.superblock : Superblock;
import btrfs.checksum : calculateChecksum;

const TYPICAL_BLOCK_SIZE = 16384;

struct BlockData
{
    align(1):

    HeaderData header;
    union {
        NodeItem[(TYPICAL_BLOCK_SIZE - HeaderData.sizeof) / NodeItem.sizeof] nodeItems;
        LeafItem[(TYPICAL_BLOCK_SIZE - HeaderData.sizeof) / LeafItem.sizeof] leafItems;
    }

    alias header this;
}

struct Block
{
    mixin loadable;
    mixin createGetters!(typeof(typeof(this.data).header));

    @nogc this(const ref Superblock superblock) pure nothrow
    {
        this._superblock = superblock;
    }

    bool process(shared const void* buffer, void delegate(ref const typeof(this) block) action = null, bool readInvalid = false)
    {
        this.offset = 0;
        this.load(buffer);
        bool hadData = this.matches();
        if (!hadData)
        {
            // Some corrupted blocks first 512 bytes can be swapped
            this.offset = 512;
            this.load(buffer + this.offset);
            hadData = this.matches();
            if (!hadData)
            {
                this.offset = 0;
                this.load(buffer);
            }
        }

        if (action && (hadData || readInvalid))
        {
            action(this);
        }

        return hadData;
    }

    @nogc const bool matches() pure nothrow
    {
        if (this.fsid != this.superblock.fsid)
        {
            return false;
        }
        return true;
    }

    const bool isValid() nothrow
    {
        if (!this.matches() || this.offset != 0)
        {
            return false;
        }
        auto checksum = calculateChecksum(this.buffer[typeof(this.data).csum.sizeof..(this.superblock.nodesize  - this.offset)], this.superblock.csumType);
        if (this.csum != checksum)
        {
            return false;
        }
        return true;
    }

    @property @nogc ref const(BlockData) data() const pure nothrow return
    {
        return *(this.rawData - this.offset);
    }

    @nogc ref const(RootItem) getRootItem(size_t offset, size_t size) const pure nothrow return
    {
        return *cast(RootItem *)(this.buffer - this.offset + HeaderData.sizeof + offset);
    }

    @nogc ref const(ChunkItem) getChunkItem(size_t offset, size_t size) const pure nothrow return
    {
        return *cast(ChunkItem *)(this.buffer - this.offset + HeaderData.sizeof + offset);
    }

    @property @nogc ref const(Superblock) superblock() const pure nothrow return
    {
        return this._superblock;
    }

private:
    ulong offset = 0;
    union
    {
        immutable(ubyte) *buffer;
        immutable(BlockData) *rawData;
    }

    Superblock _superblock;
}
