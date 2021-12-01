module btrfs.io;

mixin template loadable()
{
    @nogc void load(shared const void* buffer) pure nothrow
    {
        this.buffer = cast(immutable ubyte*)buffer;
    }

    @nogc void load(shared const ubyte* buffer) pure nothrow
    {
        this.buffer = cast(immutable ubyte*)buffer;
    }
}
