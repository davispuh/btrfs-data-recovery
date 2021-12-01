module btrfs.device;

import std.stdio : File;
import std.file : exists, getAttributes, attrIsFile;
import std.mmfile : MmFile;
import core.sys.posix.sys.mman : posix_madvise, mmap,
                                 POSIX_MADV_RANDOM, POSIX_MADV_SEQUENTIAL;
import core.sys.posix.fcntl : S_ISBLK;
import std.exception : ErrnoException;
import utils.memory : Memory;

class DeviceException : Exception
{
    this(string message)
    {
        super(message);
    }
}

synchronized class Device
{
private:
    string devicePath;
    size_t _size;
    MmFile device;
    void[] _data;

    size_t readSize()
    {
        if (!exists(this.devicePath))
        {
            throw new DeviceException("Device doesn't exist!");
        }

        auto attrs = getAttributes(this.devicePath);
        if (!attrs.attrIsFile && !S_ISBLK(attrs))
        {
            throw new DeviceException("Not a valid device!");
        }

        try
        {
            return File(this.devicePath).size;
        } catch (ErrnoException e)
        {
            throw new DeviceException(e.msg);
        }
    }

public:

    this(string devicePath, bool sequential = false)
    {
        this.devicePath = devicePath;
        this._size = this.readSize();
        try
        {
            this.device = cast(shared)(new MmFile(this.devicePath, MmFile.Mode.read, this.size, null));
        } catch (ErrnoException e)
        {
            throw new DeviceException(e.msg);
        }
        this._data = cast(shared)this[];
        posix_madvise(cast(void *)this._data.ptr, this.size, sequential ? POSIX_MADV_SEQUENTIAL : POSIX_MADV_RANDOM);
    }

    int free(ulong offset, ulong length)
    {
        auto addr = cast(void *)(this._data.ptr) + offset;
        // we can't use munmap because then other data might get allocated in this location
        // and it would be incorrectly freed on MmFile destructor
        // so instead we mmap empty mapping over it
        return Memory.get().privateMmap(addr, length);
    }

    @property @nogc const(string) path() const pure nothrow
    {
        return this.devicePath;
    }

    @property @nogc const(size_t) size() const pure nothrow
    {
        return this._size;
    }

    @property @nogc shared(const(void[])) data() const pure nothrow
    {
        return this._data;
    }

    @property shared(void[]) opSlice()
    {
        return cast(shared)(cast(MmFile)this.device)[];
    }

}
