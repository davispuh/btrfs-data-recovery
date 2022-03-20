module btrfs.fs;

import std.conv : to;
import std.range.primitives : empty;
import std.algorithm.comparison : min;
import std.container.rbtree : RedBlackTree, redBlackTree;
import std.process : pipeProcess, wait, Redirect, Config;
import std.stdio : stderr;
import std.string : fromStringz;
import std.bitmanip : littleEndianToNative;
import std.uuid : UUID;
import btrfs.device : Device, DeviceException;
import btrfs.header : FSID_SIZE, UUID_SIZE, ObjectID;
import btrfs.superblock : SUPERBLOCK_MAGIC, Superblock, loadSuperblock, isSuperblockOffset;
import btrfs.block : Block;
import btrfs.items : Key, Chunk, ItemType, ChunkType;

enum Tree
{
    none,
    all,
    root,
    chunk,
    log
}

struct OffsetInfo
{
    ulong logical;
    ulong physical;
    ulong length;
    uint mirror;
    ubyte[UUID_SIZE] devUuid;
}

class FilesystemException : Exception
{
    this(string message)
    {
        super(message);
    }
}


class FilesystemState
{
private:
    Superblock _superblock;
    Block block;
    shared(const(void[])) data;
    shared(Device[ubyte[UUID_SIZE]]) devices;
    alias ChunkTree = RedBlackTree!(const(Chunk), "a.key.offset < b.key.offset");
    ChunkTree chunks;

    void readChunks()
    {
        if (this.chunks.empty())
        {
            auto systemChunks = this._superblock.getSystemChunks();
            if (systemChunks.length <= 0)
            {
                throw new FilesystemException("Expected to have atleast one chunk array item!");
            }
            foreach (chunk; systemChunks)
            {
                if (!chunk.isValid())
                {
                    throw new FilesystemException("Invalid system chunk!");
                }
                this.chunks.insert(chunk);
            }

            if (this.chunkRoot <= 0)
            {
                throw new FilesystemException("Didn't find chunk root!");
            }

            if (!this.processChunkTree(this.chunkRoot))
            {
                throw new FilesystemException("Failed to load chunk tree!");
            }
        }
    }

    bool loadDeviceData(const ubyte[UUID_SIZE] deviceUUID, out shared const(void)[] data)
    {
        if (this.hasDevice(deviceUUID))
        {
            data = this.getDevice(deviceUUID).data();
            return true;
        }
        return false;
    }

    bool processChunkTree(ulong treeRoot)
    {
        auto chunkRootOffsets = this.getOffsetInfo(treeRoot, this.nodesize);
        foreach(chunkRootOffset; chunkRootOffsets)
        {
            if (chunkRootOffset.length != 1)
            {
                throw new FilesystemException("Unexpected chunk tree stripes!");
            }
            shared const(void)[] chunkData;
            if (!this.loadDeviceData(chunkRootOffset[0].devUuid, chunkData))
            {
                continue;
            }
            this.block.load(chunkData.ptr + chunkRootOffset[0].physical);
            auto block = this.block;
            if (block.isValid())
            {
                if (block.owner != ObjectID.CHUNK_TREE)
                {
                    throw new FilesystemException("Expected CHUNK_TREE!");
                }

                for (int i=0; i < block.nritems; i++)
                {
                    if (block.level > 0)
                    {
                        auto blockNumber = block.data.nodeItems[i].blockNumber;
                        if (!this.processChunkTree(blockNumber))
                        {
                            stderr.writeln("Corrupted block " ~ blockNumber.to!string);
                        }
                    } else
                    {
                        auto item = &block.data.leafItems[i];
                        if (item.key.type == ItemType.CHUNK_ITEM)
                        {
                            auto data = &block.getChunkItem(item.offset, item.size);
                            Chunk chunk;
                            chunk.key = &item.key;
                            chunk.item = data;
                            this.chunks.insert(chunk);
                        } else if (item.key.type != ItemType.DEV_ITEM)
                        {
                            stderr.writeln("Unexpected item " ~ item.key.type.to!string);
                        }
                    }
                }
                return true;
            }
        }
        return false;
    }

    bool findChunk(ulong logicalOffset, out Chunk chunk)
    {
        this.readChunks();
        Chunk target;
        Key key;
        key.offset = logicalOffset + 1;
        target.key = &key;
        auto chunkRange = this.chunks.lowerBound(target);
        if (chunkRange.empty())
        {
            return false;
        }
        chunk = chunkRange.back();
        if (logicalOffset < chunk.key.offset + chunk.item.length)
        {
            return true;
        }
        return false;
    }

    OffsetInfo[][] getOffsetInfo(ulong logicalOffset, ulong length, Chunk chunk) const
    {
        OffsetInfo[][] offsets;
        if (logicalOffset + length > chunk.key.offset + chunk.item.length)
        {
            throw new FilesystemException("Getting offsets when spanning chunks is not implemented!");
        }

        uint subStripes = chunk.subStripes;
        if (subStripes < 1)
        {
            subStripes = 1;
        }
        uint mirrors = chunk.numStripes / subStripes;
        uint stripeRatio = 1;
        if (chunk.type & ChunkType.RAID0)
        {
            stripeRatio = mirrors;
            mirrors = 1;
        } else if (chunk.type & ChunkType.RAID10)
        {
            stripeRatio = mirrors;
        } else if (chunk.type & ChunkType.RAID5 ||
                   chunk.type & ChunkType.RAID6)
        {
            mirrors = 1;
        }

        if (chunk.type & ChunkType.RAID5 ||
            chunk.type & ChunkType.RAID6)
        {
            throw new FilesystemException("Getting offsets for RAID5/RAID6 is not implemented!");
        }

        auto stripes = chunk.getStripes();
        for (uint mirror = 0; mirror < mirrors; mirror++)
        {
            OffsetInfo[] stripesInfo;
            ulong offsetInChunk = logicalOffset - chunk.key.offset;
            ulong endOffset = offsetInChunk + length;
            while (offsetInChunk < endOffset)
            {
                ulong stripeNr = offsetInChunk / chunk.stripeLen;
                ulong stripeIndex = (stripeNr % stripeRatio) * subStripes + mirror;
                ulong offsetInStripe = offsetInChunk % chunk.stripeLen;
                stripeNr /= stripeRatio;

                OffsetInfo info;
                info.logical = chunk.key.offset + offsetInChunk;
                info.physical = stripes[stripeIndex].offset + offsetInStripe + stripeNr * chunk.stripeLen;
                info.length = min(endOffset - offsetInChunk, chunk.stripeLen - offsetInStripe);
                info.mirror = mirror + 1;
                info.devUuid = stripes[stripeIndex].devUuid;

                stripesInfo ~= info;
                offsetInChunk += info.length;
            }
            offsets ~= stripesInfo;
        }
        return offsets;
    }

public:
    this(string devicePath)
    {
        this.chunks = new ChunkTree();
        shared Device device;
        try
        {
            device = new shared Device(devicePath, false);
        } catch (DeviceException e)
        {
            throw new FilesystemException(e.msg);
        }
        this.data = device.data();
        if (!loadSuperblock(this._superblock, this.data))
        {
            throw new FilesystemException("Invalid superblock!");
        }
        this.block = Block(this._superblock);
        this.addDevice(this.deviceUUID, device);
    }

    static FilesystemState[ubyte[FSID_SIZE]] create(string[] devices, void function(const string device, const string message) errorCallback)
    {
        FilesystemState[ubyte[FSID_SIZE]] states;
        foreach (device; devices)
        {
            FilesystemState fs;
            try
            {
                fs = new FilesystemState(device);
            } catch (FilesystemException e)
            {
                errorCallback(device, e.msg);
                continue;
            }

            if (!fs.isValid())
            {
                errorCallback(device, "Invalid superblock!");
                continue;
            }

            if (fs.fsid in states)
            {
                states[fs.fsid].addDevice(fs.deviceUUID, device);
                continue;
            }

            states[fs.fsid] = fs;
        }

        return states;
    }

    bool isValid() const
    {
        return this._superblock.magic == SUPERBLOCK_MAGIC;
    }

    @property Superblock superblock() const shared
    {
        return this._superblock;
    }

    @property ulong nodesize() const
    {
        return this._superblock.nodesize;
    }

    @property const(ubyte[FSID_SIZE]) fsid() const
    {
        return this._superblock.fsid;
    }

    @property const(ubyte[UUID_SIZE]) deviceUUID() const
    {
        return this._superblock.devItem.uuid;
    }

    @property ulong root() const
    {
        return this._superblock.root;
    }

    @property ulong root() const shared
    {
        return (cast(FilesystemState)this)._superblock.root;
    }

    @property ulong chunkRoot() const
    {
        return this._superblock.chunkRoot;
    }

    @property ulong chunkRoot() const shared
    {
        return (cast(FilesystemState)this)._superblock.chunkRoot;
    }

    @property ulong logRoot() const
    {
        return this._superblock.logRoot;
    }

    @property string label() const
    {
        auto name = (cast(Superblock)this._superblock).label;
        if (name[0] != '\0')
        {
            return fromStringz(name.ptr).to!string;
        }
        return UUID(this.fsid).toString;
    }

    ulong getTreeRoot(Tree tree) const
    {
        switch (tree)
        {
            case Tree.root:
                return this.root;
            case Tree.chunk:
                return this.chunkRoot;
            case Tree.log:
                return this.logRoot;
            default:
                assert(0);
        }
    }

    ulong getExpectedGeneration(ulong tree) const
    {
        if (tree == this.root || isSuperblockOffset(tree))
        {
            return this._superblock.generation;
        } else if (tree == this.chunkRoot)
        {
            return this._superblock.chunkRootGeneration;
        }

        throw new FilesystemException("Not implemented for tree: " ~ tree.to!string);
    }

    ref shared(Device) addDevice(const ubyte[UUID_SIZE] deviceUUID, shared Device device)
    {
        this.devices[deviceUUID] = device;
        return this.devices[deviceUUID];
    }

    ref shared(Device) addDevice(const ubyte[UUID_SIZE] deviceUUID, string path)
    {
        try
        {
            return this.addDevice(deviceUUID, new shared Device(path));
        } catch (DeviceException e)
        {
            throw new FilesystemException(e.msg);
        }
    }

    bool hasDevice(const ubyte[UUID_SIZE] deviceUUID) const
    {
        if (deviceUUID in this.devices)
        {
            return true;
        }
        return false;
    }

    ulong missingDeviceCount() const
    {
        return this._superblock.numDevices - this.devices.length;
    }

    shared(Device) getDevice(const ubyte[UUID_SIZE] deviceUUID)
    {
        return this.devices[deviceUUID];
    }

    const(ubyte[UUID_SIZE])[] getAllDeviceUUIDs() const
    {
        return (cast(Device[ubyte[UUID_SIZE]])this.devices).keys;
    }

    shared(Device[ubyte[UUID_SIZE]]) getAllDevices() shared
    {
        return this.devices;
    }

    OffsetInfo[][] getOffsetInfo(ulong logicalOffset, ulong length)
    {
        Chunk chunk;
        if (this.findChunk(logicalOffset, chunk))
        {
            return this.getOffsetInfo(logicalOffset, length, chunk);
        }
        return [];
    }

    synchronized OffsetInfo[][] getOffsetInfo(ulong logicalOffset, ulong length)
    {
        Chunk chunk;
        bool chunkFound = false;
        synchronized
        {
            chunkFound = (cast(FilesystemState)this).findChunk(logicalOffset, chunk);
        }
        if (chunkFound)
        {
            return (cast(FilesystemState)this).getOffsetInfo(logicalOffset, length, chunk);
        }
        return [];
    }
}
