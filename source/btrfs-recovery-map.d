module btrfs.cli.recovery.map;

import std.stdio : stdout, stdin, stderr, readln;
import std.getopt : getopt, config, arraySep, defaultGetoptPrinter;
import std.conv : to, ConvException;
import std.algorithm.sorting : sort;
import std.algorithm.iteration : uniq, map, splitter;
import std.array : array, join;
import std.json : toJSON, JSONValue, JSONOptions;
import std.string : strip;
import std.uuid : UUID;
import core.sys.posix.unistd : isatty;
import btrfs.device : Device, DeviceException;
import btrfs.superblock : Superblock, loadSuperblock;
import btrfs.block : Block;
import btrfs.items : ItemType;
import btrfs.fs : FilesystemState, FilesystemException, OffsetInfo;
import btrfs.header : FSID_SIZE, UUID_SIZE;

int main(string[] args)
{
    string[] devices;
    ulong size = 0;

    try
    {
        arraySep = ",";
        auto optionInfo = getopt(args, config.required, "devices|d", "Device paths", &devices,
                                       "size|s", "Size", &size);
        if (optionInfo.helpWanted)
        {
            defaultGetoptPrinter("Usage: " ~ args[0] ~ " [options] <blocks...>", optionInfo.options);
            return 0;
        }
    } catch (Exception e)
    {
        stderr.writeln(e.msg);
        return -1;
    }

    ulong[] blocks;
    try
    {
        blocks = args[1..$].sort.uniq.map!(b => b.to!ulong).array;
    } catch (ConvException e)
    {
        stderr.writeln("Invalid block number: " ~ args[1..$].join(", "));
        return -1;
    }

    if (!isatty(stdin.fileno))
    {
        char[] line;
        while (readln(line) > 0)
        {
            try
            {
                blocks ~= line.strip.splitter(",").map!(b => b.to!ulong).array;
            } catch (ConvException e)
            {
                stderr.writeln("Invalid block number: " ~ line);
                return -1;
            }
        }
        blocks = blocks.sort.uniq.array;
    }

    if (blocks.length <= 0)
    {
        stderr.writeln("You need to specify atleast one block to map!");
        return -1;
    }

    if (size <= 0)
    {
        size = 16384;
    }

    FilesystemState[ubyte[FSID_SIZE]] filesystemStates = FilesystemState.create(devices, (const string device, const string message)
    {
        stderr.writeln(device ~ ": " ~ message);
    });

    if (filesystemStates.length == 0)
    {
        stderr.writeln("No BTRFS filesystem!");
        return -2;
    }

    string[ubyte[UUID_SIZE]] devicePaths;
    JSONValue[string] blocksJSON;
    foreach (block; blocks)
    {
        OffsetInfo[][] offsetMirrors;
        foreach (fsid, fs; filesystemStates)
        {
            try
            {
                offsetMirrors ~= fs.getOffsetInfo(block, size);
                foreach (offsetStripes; offsetMirrors)
                {
                    foreach (offsetInfo; offsetStripes)
                    {
                        if (offsetInfo.devUuid !in devicePaths && fs.hasDevice(offsetInfo.devUuid))
                        {
                            devicePaths[offsetInfo.devUuid] = fs.getDevice(offsetInfo.devUuid).path;
                        }
                    }
                }
            } catch (FilesystemException e)
            {
                continue;
            }
        }

        JSONValue[] mirrorsJSON;
        foreach (offsetStripes; offsetMirrors)
        {
            JSONValue[] stripesJSON;
            foreach (offsetInfo; offsetStripes)
            {
                JSONValue[string] offsetJSON;
                offsetJSON["logical"] = offsetInfo.logical;
                offsetJSON["physical"] = offsetInfo.physical;
                offsetJSON["length"] = offsetInfo.length;
                offsetJSON["mirror"] = offsetInfo.mirror;
                offsetJSON["device"] = offsetInfo.devUuid in devicePaths ? devicePaths[offsetInfo.devUuid] : "MISSING";
                offsetJSON["deviceUUID"] = UUID(offsetInfo.devUuid).toString();
                stripesJSON ~= JSONValue(offsetJSON);
            }
            mirrorsJSON ~= JSONValue(stripesJSON);
        }
        blocksJSON[block.to!string] = mirrorsJSON;
    }

    auto json = JSONValue(blocksJSON);
    stdout.writeln(toJSON(json, true, JSONOptions.doNotEscapeSlashes));

    return 0;
}
