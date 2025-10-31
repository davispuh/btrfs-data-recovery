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

const size_t MAX_MMAP_SIZE = 8UL * 1024 * 1024 * 1024; // 8GB threshold

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
    const size_t BUFFER_SIZE = 64 * 1024 * 1024; // 64MB buffer

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
        this.useMmap = this._size <= MAX_MMAP_SIZE;
        this.bufferOffset = size_t.max; // Invalid offset to force initial read

        if (this.useMmap)
        {
            try
            {
                this.device = cast(shared)(new MmFile(this.devicePath, MmFile.Mode.read, this.size, null));
                this._data = cast(shared)this[];
                posix_madvise(cast(void *)this._data.ptr, this.size, sequential ? POSIX_MADV_SEQUENTIAL : POSIX_MADV_RANDOM);
            } catch (ErrnoException e)
            {
                this.useMmap = false;
                this._buffer = new void[this.BUFFER_SIZE];
            }
        }
        else
        {
            this._buffer = new void[this.BUFFER_SIZE];
        }
    }

    // Efficient dataPtr with caching for large devices
    shared(const(void*)) dataPtr(size_t offset, size_t length = 1)
    {
        if (offset >= this._size)
        {
            throw new DeviceException("Offset beyond device size");
        }

        if (this.useMmap)
        {
            return cast(shared(const(void*)))(this._data.ptr + offset);
        }
        else
        {
            // For large devices, use buffered reading with caching
            auto actualLength = min(length, this._size - offset);

            // Check if the requested data is already in the buffer
            if (offset >= this.bufferOffset && offset + actualLength <= this.bufferOffset + this._buffer.length)
            {
                return cast(shared(const(void*)))(this._buffer.ptr + (offset - this.bufferOffset));
            }

            // Need to read new data into buffer
            // Align buffer reads to page boundaries for better performance
            size_t alignedOffset = (offset / this.BUFFER_SIZE) * this.BUFFER_SIZE;
            size_t readSize = min(this.BUFFER_SIZE, this._size - alignedOffset);

            try
            {
                auto tempFile = File(this.devicePath, "rb");
                tempFile.seek(alignedOffset);
                auto bufferSlice = cast(ubyte[])this._buffer[0..readSize];
                auto bytesRead = tempFile.rawRead(bufferSlice);
                tempFile.close();

                if (bytesRead.length != readSize)
                {
                    throw new DeviceException("Failed to read expected amount of data");
                }

                this.bufferOffset = alignedOffset;

                // Return pointer to the requested data within the buffer
                return cast(shared(const(void*)))(this._buffer.ptr + (offset - alignedOffset));
            } catch (ErrnoException e)
            {
                throw new DeviceException(e.msg);
            }
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

    @property string path() const pure nothrow
    {
        return this.devicePath;
    }

    @property size_t size() const pure nothrow
    {
        return this._size;
    }

    @property shared(const(void[])) data() const pure nothrow
    {
        if (this.useMmap)
        {
            return cast(shared(const(void[])))this._data;
        }
        else
        {
            // For file access, return a dummy slice - actual data access goes through dataPtr
            return cast(shared(const(void[])))(cast(void[])[]).ptr[0..this._size];
        }
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

}
