module utils.memory;

import std.file : readText;
import std.string : strip;
import std.conv : to;
import core.sys.posix.sys.mman : mmap,
                                 PROT_NONE, MAP_PRIVATE, MAP_ANON, MAP_FIXED;

const RATIO = 0.40;

class Memory
{
private:
    static bool created;
    __gshared Memory instance;

    size_t allowedCount;
    size_t currentCount = 0;

    this()
    {
        this.allowedCount = cast(size_t)(readText("/proc/sys/vm/max_map_count").strip.to!size_t * RATIO);
    }

public:
    static Memory get()
    {
        if (!created)
        {
            synchronized(Memory.classinfo)
            {
                if (!instance)
                {
                    instance = new Memory();
                }
                created = true;
            }
        }
        return instance;
    }

    int privateMmap(void* addr, size_t length)
    {
        if (this.currentCount >= this.allowedCount)
        {
            // we have reached maximum allowed count of mmap's so we don't do anything anymore
            return 0;
        }
        this.currentCount++;

        auto mmapAddr = mmap(addr, length, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (mmapAddr != addr)
        {
            return cast(int)mmapAddr;
        }

        return 0;
    }
}
