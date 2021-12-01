module btrfs.checksum;

import std.bitmanip : nativeToLittleEndian;
import std.digest : digest;
import std.digest.crc : CRC;
import std.digest.sha : sha256Of;
import xxhash : xxhashOf;
import crypto.blake2.blake2b : blake2b, B256;

const CSUM_SIZE = 32;

alias CRC32C = CRC!(32u, 0x82F63B78);

enum ChecksumType : ushort
{
    CRC32  = 0,
    XXHASH = 1,
    SHA256 = 2,
    BLAKE2 = 3
}

const(ubyte[CSUM_SIZE]) calculateChecksum(const ubyte[] data, const ChecksumType checksumType) nothrow
{
    ubyte[CSUM_SIZE] result;
    switch (checksumType)
    {
        case ChecksumType.CRC32:
            auto value = digest!CRC32C(data);
            result[0..value.sizeof] = value;
            break;
        case ChecksumType.XXHASH:
            // We're missing xxhash64 implementation, xxhashOf is only 32-bit so this isn't correct
            // TODO: Get xxhash64 implementation
            auto value = nativeToLittleEndian(xxhashOf(data));
            result[0..value.sizeof] = value;
            assert(0); // break;
        case ChecksumType.SHA256:
            result = sha256Of(data);
            break;
        case ChecksumType.BLAKE2:
            blake2b(&result[0], B256, data);
            break;
        default:
            assert(false);
    }

    return result;
}
