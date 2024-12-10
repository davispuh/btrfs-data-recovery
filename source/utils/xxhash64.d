module utils.xxhash64;

import std.bitmanip : swapEndian;

enum Prime64_1 = 11400714785074694791U;
enum Prime64_2 = 14029467366897019727U;
enum Prime64_3 = 1609587929392839161U;
enum Prime64_4 = 9650029242287828579U;
enum Prime64_5 = 2870177450012600261U;

@trusted pure nothrow
ulong xxhash64Of(in ubyte[] source, ulong seed = 0)
{
    auto srcPtr = cast(const(ulong)*)source.ptr;
    auto srcEnd = cast(const(ulong)*)(source.ptr + source.length);
    ulong result = void;

    if (source.length >= 32)
    {
        auto limit = srcEnd - 4;
        ulong v1 = seed + Prime64_1 + Prime64_2;
        ulong v2 = seed + Prime64_2;
        ulong v3 = seed;
        ulong v4 = seed - Prime64_1;

        do
        {
            round(v1, srcPtr);
            srcPtr++;

            round(v2, srcPtr);
            srcPtr++;

            round(v3, srcPtr);
            srcPtr++;

            round(v4, srcPtr);
            srcPtr++;
        } while (srcPtr <= limit);

        result = rotateLeft(v1, 1) + rotateLeft(v2, 7) + rotateLeft(v3, 12) + rotateLeft(v4, 18);
        mergeAccumulator(result, v1);
        mergeAccumulator(result, v2);
        mergeAccumulator(result, v3);
        mergeAccumulator(result, v4);
    } else
    {
        result = seed + Prime64_5;
    }

    result += source.length;

    while (srcPtr <= srcEnd - 1)
    {
        result ^= rotateLeft(loadUlong(srcPtr) * Prime64_2, 31) * Prime64_1;
        result = rotateLeft(result, 27) * Prime64_1;
        result += Prime64_4;
        srcPtr++;
    }

    auto ptr = cast(const(ubyte)*)srcPtr;
    auto end = cast(const(ubyte)*)srcEnd;

    if (end - ptr >= 4)
    {
        result ^= loadUint(cast(const(uint*))ptr) * Prime64_1;
        result = rotateLeft(result, 23) * Prime64_2;
        result += Prime64_3;
        ptr += 4;
    }

    while (ptr < end)
    {
        result ^= *ptr * Prime64_5;
        result = rotateLeft(result, 11) * Prime64_1;
        ptr++;
    }

    result ^= result >> 33;
    result *= Prime64_2;
    result ^= result >> 29;
    result *= Prime64_3;
    result ^= result >> 32;

    return result;
}

@safe pure nothrow
void round(ref ulong acc, in ulong* source)
{
    acc += loadUlong(source) * Prime64_2;
    acc = rotateLeft(acc, 31);
    acc *= Prime64_1;
}

@safe pure nothrow
void mergeAccumulator(ref ulong acc, in ulong accN)
{
    acc ^= rotateLeft(accN * Prime64_2, 31) * Prime64_1;
    acc *= Prime64_1;
    acc += Prime64_4;
}

@safe pure nothrow
ulong rotateLeft(in ulong x, in ulong n)
{
    return (x << n) | (x >> (64 - n));
}

@safe pure nothrow
uint loadUint(in uint* source)
{
    version (LittleEndian)
        return *source;
    else
        return swapEndian(*source);
}

@safe pure nothrow
ulong loadUlong(in ulong* source)
{
    version (LittleEndian)
        return *source;
    else
        return swapEndian(*source);
}
