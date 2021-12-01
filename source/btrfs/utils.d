module btrfs.utils;

public import std.traits : isScalarType, isArray;
public import std.bitmanip : littleEndianToNative;

string getterMixin(string getterName)()
{
    return q{
        @property @nogc const(typeof(field)) } ~ getterName ~ q{() const pure nothrow return
        {
            ubyte[field.sizeof] data = this.buffer[field.offsetof..(field.offsetof + field.sizeof)];
            static if (isArray!(typeof(field)))
            {
                return cast(typeof(field))data;
            } else
            {
                return littleEndianToNative!(typeof(field))(data);
            }
        }
    };
}

mixin template createGetters(alias data)
{
    static foreach (field; data.tupleof)
    {
        static if (isScalarType!(typeof(field)) ||
                  (isArray!(typeof(field)) && isScalarType!(typeof(field[0]))) ||
                  is(typeof(field) == ChecksumType))
        {
            mixin(getterMixin!(field.stringof));
        }
    }
}
