module btrfs.scanner;

import std.conv : to;
import std.algorithm.comparison : min;
import std.algorithm.searching : canFind;
import std.container : DList;
import std.concurrency : Tid, thisTid, ownerTid, send, prioritySend,
                         receive, receiveTimeout,
                         OwnerTerminated, TidMissingException;
import std.exception : ErrnoException;
import core.time : Duration;
import btrfs.device : Device, DeviceException;
import btrfs.header : UUID_SIZE, ObjectID;
import btrfs.superblock : Superblock, isSuperblockOffset, loadSuperblock;
import btrfs.block : Block;
import btrfs.items : ItemType;
import btrfs.fs : OffsetInfo, FilesystemState, FilesystemException;

enum Status
{
    STARTED,
    WORKING,
    ERRORED,
    ABORTED,
    FINISHED
}

enum DataType
{
    None,
    Superblock,
    Block,
    Ref,
    Message
}

struct Progress
{
    string device;
    union
    {
        size_t size = 0;
        size_t count;
    }
    size_t progress = 0;
    size_t offset = 0;
    size_t tree = 0;
    Status status = Status.STARTED;
    Tid thread;
    ubyte[UUID_SIZE] deviceUuid;
    size_t bytenr = 0;
    ObjectID owner = ObjectID.INVALID;
    DataType dataType;
    union
    {
        Superblock superblock;
        Block block;
        char[200] message;
        struct RefInfo
        {
            ulong child;
            ulong generation;
        };
        RefInfo refInfo;
    }
}

class ScannerException : Exception
{
    Progress progress;
    bool noOwner;
    this(Progress progress, bool noOwner = false)
    {
        this.progress = progress;
        this.noOwner = noOwner;
        super("ScannerException");
    }
}

class Scanner
{
private:
    const MEM_FREE_START = 0x100000;
    Progress progress;
    shared Device device = null;
    shared FilesystemState fs = null;
    shared(const(void)[]) data;
    size_t memFreeOffset = MEM_FREE_START;
    Superblock masterSuperblock;
    Superblock superblock;
    Block block;

    void init()
    {
        this.progress.thread = thisTid;
        this.progress.status = Status.STARTED;
        this.progress.dataType = DataType.None;
    }

    bool loadDevice(const ubyte[UUID_SIZE] deviceUUID)
    {
        auto fs = cast(FilesystemState)this.fs;
        if (fs.hasDevice(deviceUUID))
        {
            this.device = fs.getDevice(deviceUUID);
            this.data = this.device.data();
            this.progress.deviceUuid = deviceUUID;
            return true;
        }
        return false;
    }

    bool processBlock(size_t offset, void delegate(const ref Block block) action, bool readInvalid = false)
    {
        if (offset + this.masterSuperblock.nodesize >= this.data.length)
        {
            return false;
        }
        return this.block.process(this.data.ptr + offset, action, readInvalid);
    }

    bool checkForMessages()
    {
        bool shouldAbort = false;
        receiveTimeout(Duration.zero,
            (Status status)
            {
                this.progress.status = (status == Status.ABORTED ? status : Status.ERRORED);
                this.progress.dataType = DataType.None;
                ownerTid.prioritySend(this.progress);
                shouldAbort = true;
            },

            (Progress completedProgress)
            {
                if (completedProgress.offset >= MEM_FREE_START && !isSuperblockOffset(completedProgress.offset))
                {
                    auto offset = (completedProgress.offset / this.masterSuperblock.nodesize) * this.masterSuperblock.nodesize;
                    auto device = this.device;
                    auto result = 0;
                    if (completedProgress.deviceUuid != this.progress.deviceUuid)
                    {
                        assert(!(this.fs is null));
                        device = (cast(FilesystemState)this.fs).getDevice(completedProgress.deviceUuid);
                    }
                    if (this.progress.tree == 0)
                    {
                        result = device.free(this.memFreeOffset, offset - this.memFreeOffset + this.masterSuperblock.nodesize);
                        this.memFreeOffset = offset + this.masterSuperblock.nodesize;
                    } else if (completedProgress.block.isNode() || completedProgress.block.owner != ObjectID.CHUNK_TREE)
                    {
                        // we don't want to free Chunk items
                        result = device.free(offset, this.masterSuperblock.nodesize);
                    }
                    if (result != 0)
                    {
                        throw new ErrnoException("Failed to free/remap device mapping!");
                    }
                }
            },

            (OwnerTerminated e)
            {
                this.progress.status = Status.ERRORED;
                this.progress.dataType = DataType.None;
                throw new ScannerException(this.progress, true);
            }
        );

        try
        {
            ownerTid;
        } catch (TidMissingException e)
        {
            this.progress.status = Status.ERRORED;
            this.progress.dataType = DataType.None;
            throw new ScannerException(this.progress, true);
        }

        return shouldAbort;
    }

    void waitForComplete()
    {
        this.progress.status = Status.WORKING;
        while (this.progress.status == Status.WORKING)
        {
            receive(
                (Status status)
                {
                    this.progress.status = status;
                },

                (OwnerTerminated e)
                {
                    // just exit
                    this.progress.status = Status.ABORTED;
                }
            );
        }
    }

public:

    this(string devicePath)
    {
        this.progress.device = devicePath;
        try
        {
            this.device = new shared Device(devicePath, true);
        } catch (DeviceException e)
        {
            this.init();
            setProgressError(progress, e.msg);
            ownerTid.send(this.progress);

            this.progress.dataType = DataType.None;
            this.progress.status = Status.ERRORED;
            throw new ScannerException(this.progress);
        }
        this(this.device);
    }

    this(shared Device device)
    {
        this.init();
        this.device = device;
        this.progress.device = this.device.path;
        this.progress.size = this.device.size;
        ownerTid.send(this.progress);
        this.data = this.device.data();

        if (!loadSuperblock(this.masterSuperblock, this.data))
        {
            this.progress.dataType = DataType.Message;
            this.progress.message = "Invalid superblock!";
            this.progress.status = Status.ERRORED;
            throw new ScannerException(this.progress);
        }
        this.block = Block(this.masterSuperblock);
        this.progress.dataType = DataType.Superblock;
        this.progress.deviceUuid = this.masterSuperblock.devItem.uuid;
        this.progress.superblock = this.masterSuperblock;
        ownerTid.send(this.progress);
    }

    this(shared FilesystemState fs)
    {
        this.init();
        this.fs = fs;
        this.progress.device = (cast(FilesystemState)this.fs).label;
        this.masterSuperblock = this.fs.superblock;
        this.block = Block(this.masterSuperblock);
        this.progress.size = this.masterSuperblock.totalBytes;
        ownerTid.send(this.progress);

        auto allDevices = this.fs.getAllDevices();
        foreach (devUuid, device; allDevices)
        {
            this.progress.dataType = DataType.Superblock;
            if (this.loadDevice(devUuid))
            {
                loadSuperblock(this.superblock, this.data);
                this.progress.superblock = this.superblock;
                ownerTid.send(this.progress);
            }
        }
    }

    void scan()
    {
        this.progress.status = Status.WORKING;
        bool hadData = false;
        while (this.progress.status == Status.WORKING && this.progress.offset + this.masterSuperblock.nodesize < this.data.length)
        {
            this.progress.progress = this.progress.offset;
            if (this.checkForMessages())
            {
                break;
            }
            if (!isSuperblockOffset(this.progress.offset))
            {
                hadData = this.processBlock(this.progress.offset, (const ref Block block)
                {
                    this.progress.dataType = DataType.Block;
                    this.progress.block = block;
                    this.progress.bytenr = block.bytenr;
                    ownerTid.send(this.progress);
                });
            } else
            {
                hadData = this.superblock.process(this.data.ptr + this.progress.offset, (const ref Superblock superblock)
                {
                    this.progress.dataType = DataType.Superblock;
                    this.progress.superblock = superblock;
                    this.progress.bytenr = superblock.bytenr;
                    ownerTid.send(this.progress);
                });
            }

            if (!hadData)
            {
                this.progress.dataType = DataType.None;
                ownerTid.send(this.progress);
            }

            this.progress.offset += this.masterSuperblock.sectorsize;
        }

        if (this.progress.status == Status.WORKING)
        {
            this.progress.status = Status.FINISHED;
            this.progress.dataType = DataType.None;
            ownerTid.send(this.progress);
        }

        this.waitForComplete();
    }

    void scanBlock(ulong block, ref bool[ulong][ubyte[UUID_SIZE]] scannedBlocks, bool isFinal = true)
    {
        this.progress.dataType = DataType.None;
        this.progress.tree = block;
        this.progress.owner = ObjectID.INVALID;
        this.progress.count = 1;
        this.progress.progress = 0;
        ownerTid.send(this.progress);
        this.progress.status = Status.WORKING;

        if (!this.fs)
        {
            this.progress.dataType = DataType.Message;
            this.progress.message = "FilesystemState must be set!";
            this.progress.status = Status.ERRORED;
            throw new ScannerException(this.progress);
        }

        if ([this.fs.root, this.fs.chunkRoot].canFind(block))
        {
            this.progress.dataType = DataType.Ref;
            this.progress.bytenr = this.fs.superblock.bytenr;
            this.progress.refInfo.child = block;
            this.progress.refInfo.generation = (cast(FilesystemState)this.fs).getExpectedGeneration(block);
            ownerTid.send(this.progress);
        }

        auto blocks = DList!(ulong[])();
        bool[ulong] processedBlocks;
        blocks ~= [block, ObjectID.INVALID];
        processedBlocks[block] = true;

        auto anyData = false;
        auto anyError = false;
        while (this.progress.status == Status.WORKING && !blocks.empty)
        {
            if (this.checkForMessages())
            {
                break;
            }

            this.progress.bytenr = blocks.front[0];
            this.progress.owner = cast(ObjectID)blocks.front[1];
            blocks.removeFront();
            this.progress.progress++;
            OffsetInfo[][] offsetMirrors;
            try
            {
                offsetMirrors = this.fs.getOffsetInfo(this.progress.bytenr, this.masterSuperblock.nodesize);
            } catch (FilesystemException e)
            {
                setProgressError(progress, e.msg);
                throw new ScannerException(this.progress);
            }

            foreach (offsetStripes; offsetMirrors)
            {
                if (offsetStripes.length != 1)
                {
                    this.progress.dataType = DataType.Message;
                    this.progress.message = "Unexpected stripe count for block " ~ this.progress.bytenr.to!string;
                    this.progress.status = Status.ERRORED;
                    throw new ScannerException(this.progress);
                }

                this.progress.offset = offsetStripes[0].physical;
                if (offsetStripes[0].devUuid in scannedBlocks &&
                    this.progress.offset in scannedBlocks[offsetStripes[0].devUuid])
                {
                    continue;
                }
                scannedBlocks[offsetStripes[0].devUuid][this.progress.offset] = true;

                if (this.progress.deviceUuid != offsetStripes[0].devUuid)
                {
                    if (!this.loadDevice(offsetStripes[0].devUuid))
                    {
                        continue;
                    }
                }

                auto hadData = this.processBlock(this.progress.offset, (const ref Block block)
                {
                    if (this.progress.owner == ObjectID.INVALID)
                    {
                        this.progress.owner = block.owner;
                    }
                    if (block.matches() && block.owner == this.progress.owner)
                    {
                        if (block.isNode())
                        {
                            for (int i=0; i < block.nritems; i++)
                            {
                                if ((block.data.nodeItems[i].blockNumber % this.masterSuperblock.sectorsize) == 0)
                                {
                                    auto activeBlock = block.data.nodeItems[i].blockNumber;

                                    this.progress.dataType = DataType.Ref;
                                    this.progress.refInfo.child = activeBlock;
                                    this.progress.refInfo.generation = block.data.nodeItems[i].generation;
                                    ownerTid.send(this.progress);

                                    if (!(activeBlock in processedBlocks))
                                    {
                                        processedBlocks[activeBlock] = true;
                                        blocks ~= [activeBlock, this.progress.owner];
                                        this.progress.count++;
                                    }
                                } else
                                {
                                    anyError = true;
                                }
                            }
                        } else if (block.owner == ObjectID.ROOT_TREE)
                        {
                            for (int i=0; i < block.nritems; i++)
                            {
                                auto item = block.data.leafItems[i];
                                if (item.key.type == ItemType.ROOT_ITEM)
                                {
                                    auto data = block.getRootItem(item.offset, item.size);
                                    if ((data.bytenr % this.masterSuperblock.sectorsize) == 0)
                                    {
                                        this.progress.dataType = DataType.Ref;
                                        this.progress.refInfo.child = data.bytenr;
                                        this.progress.refInfo.generation = data.generation;
                                        ownerTid.send(this.progress);

                                        if (!(data.bytenr in processedBlocks))
                                        {
                                            processedBlocks[data.bytenr] = true;
                                            blocks ~= [data.bytenr, item.key.objectid];
                                            this.progress.count++;
                                        }
                                    } else
                                    {
                                        anyError = true;
                                    }
                                }
                            }
                        }/* else if ([ObjectID.FS_TREE,
                                    ObjectID.EXTENT_TREE,
                                    ObjectID.CSUM_TREE,
                                    ObjectID.CHUNK_TREE,
                                    ObjectID.DEV_TREE,
                                    ObjectID.UUID_TREE,
                                    ObjectID.DATA_RELOC_TREE_OBJECTID].canFind(block.owner))
                        {
                            // nothing useful for us here
                        }*/
                    } else
                    {
                        anyError = true;
                    }
                    this.progress.dataType = DataType.Block;
                    this.progress.block = block;
                    ownerTid.send(this.progress);
                }, true);

                if (hadData && this.block.matches())
                {
                    anyData = true;
                } else
                {
                    anyError = true;
                }
            }
        }

        if (anyData && anyError)
        {
            this.progress.dataType = DataType.Message;
            string msg = "Some errors for block (" ~ this.progress.tree.to!string ~ ")!";
            this.progress.message[0..msg.length] = msg;
            ownerTid.send(this.progress);
        }

        /*
        if (!anyData)
        {
            this.progress.dataType = DataType.Message;
            string msg = "Invalid block (" ~ this.progress.tree.to!string ~ ")!";
            this.progress.message[0..msg.length] = msg;
            ownerTid.send(this.progress);
        }
        */

        if (isFinal && this.progress.status == Status.WORKING)
        {
                this.progress.status = Status.FINISHED;
                this.progress.dataType = DataType.None;
                ownerTid.send(this.progress);
        }

        this.checkForMessages();
        if (isFinal)
        {
            this.waitForComplete();
        }
    }

    static void setProgressError(ref Progress progress, string message)
    {
        progress.dataType = DataType.Message;
        size_t length = message.length.min(progress.message.sizeof);
        progress.message[0..length] = message[0..length];
        progress.status = Status.ERRORED;
    }

    static void handleException(string device, void delegate() fn)
    {
        bool waitForComplete = false;
        try
        {
            fn();
        } catch (ScannerException e)
        {
            if (!e.noOwner)
            {
                ownerTid.send(e.progress);
                waitForComplete = true;
            }
        } catch (Throwable e)
        {
            Progress progress;
            progress.thread = thisTid;
            progress.device = device;
            setProgressError(progress, e.toString());
            ownerTid.send(progress);
            waitForComplete = true;
        }
        while (waitForComplete)
        {
            receive(
                (Status status)
                {
                    if (status == Status.ERRORED ||
                        status == Status.ABORTED ||
                        status == Status.FINISHED)
                    {
                        waitForComplete = false;
                    }
                },

                (OwnerTerminated e)
                {
                    // just exit
                    waitForComplete = false;
                }
            );
        }
    }

    static void scanDevice(string devicePath)
    {
        handleException(devicePath, ()
        {
            auto scanner = new Scanner(devicePath);
            scanner.scan();
        });
    }

    static void scanBlocks(shared FilesystemState fs, immutable ulong[] blocks)
    {
        auto label = (cast(FilesystemState)fs).label;
        handleException(label, ()
        {
            bool[ulong][ubyte[UUID_SIZE]] scannedBlocks;
            auto scanner = new Scanner(fs);
            foreach (i, block; blocks)
            {
                scanner.scanBlock(block, scannedBlocks, (i + 1) == blocks.length);
            }
        });
    }
}
