module btrfs.device;

import std.stdio : File;
import std.file : exists, getAttributes, attrIsFile;
import std.mmfile : MmFile;
import core.sys.posix.sys.mman : posix_madvise, mmap,
                                  POSIX_MADV_RANDOM, POSIX_MADV_SEQUENTIAL;
import core.sys.posix.fcntl : S_ISBLK;
import std.exception : ErrnoException;
import std.algorithm.comparison : min;
import utils.memory : Memory;

const size_t MAX_MMAP_SIZE = 100UL * 1024 * 1024 * 1024 * 1024; // 100 TB threshold for mmap

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
    void[] _buffer;
    size_t bufferOffset;
    bool useMmap;
    const size_t BUFFER_SIZE = 64 * 1024 * 1024; // 64MB buffer - needs benchmarking for optimal size

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
        this.useMmap = true; // Always attempt mmap for the first MAX_MMAP_SIZE

        size_t mmapSize = min(this._size, MAX_MMAP_SIZE);

        try
        {
            this.device = cast(shared)(new MmFile(this.devicePath, MmFile.Mode.read, mmapSize, null));
            this._data = cast(shared)this[];
            posix_madvise(cast(void *)this._data.ptr, mmapSize, sequential ? POSIX_MADV_SEQUENTIAL : POSIX_MADV_RANDOM);
        } catch (ErrnoException e)
        {
            this.useMmap = false;
            this._buffer = new void[this.BUFFER_SIZE];
        }
    }

    @property string path() const pure nothrow
    {
        return this.devicePath;
    }

    @property size_t size() const pure nothrow
    {
        return this._size;
    }

    @property shared(void[]) opSlice()
    {
        if (this.useMmap)
        {
            return cast(shared)(cast(MmFile)this.device)[];
        }
        else
        {
            // For file access, return a dummy slice - actual data access goes through dataPtr
            return cast(shared)((cast(void[])[]).ptr[0..this._size]);
        }
    }

    // Simple dataPtr implementation that works for both mmap and file access
    shared(const(void*)) dataPtr(size_t offset, size_t length = 1)
    {
        if (offset >= this._size)
        {
            throw new DeviceException("Offset beyond device size");
        }

        if (this.useMmap && offset < MAX_MMAP_SIZE)
        {
            return cast(shared(const(void*)))(this._data.ptr + offset);
        }
        else
        {
            // For offsets beyond MAX_MMAP_SIZE or when mmap failed, read data directly from file
            // Allocate a temporary buffer for this read
            auto actualLength = min(length, this._size - offset);
            void[] tempBuffer = new void[actualLength];

            auto tempFile = File(this.devicePath, "rb");
            tempFile.seek(offset);
            auto bufferSlice = cast(ubyte[])tempBuffer;
            auto bytesRead = tempFile.rawRead(bufferSlice);
            tempFile.close();

            if (bytesRead.length != actualLength)
            {
                throw new DeviceException("Failed to read expected amount of data");
            }

            // Store the buffer so it can be returned as a pointer
            // Note: This is not thread-safe for concurrent access to different offsets
            this._buffer = cast(shared)tempBuffer;
            this.bufferOffset = offset;

            return cast(shared(const(void*)))this._buffer.ptr;
        }
    }

    int free(ulong offset, ulong length)
    {
        if (!this.useMmap)
        {
            // For file-based access, we can't free memory, so just return success
            return 0;
        }
        
        auto addr = cast(void *)(this._data.ptr) + offset;
        // we can't use munmap because then other data might get allocated in this location
        // and it would be incorrectly freed on MmFile destructor
        // so instead we mmap empty mapping over it
        return Memory.get().privateMmap(addr, length);
    }
}
