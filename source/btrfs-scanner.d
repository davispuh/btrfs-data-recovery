module btrfs.cli.scanner;

import std.stdio : stderr;
import std.getopt : getopt, config, defaultGetoptPrinter;
import std.conv : to;
import std.format : format;
import std.algorithm.searching : maxElement, countUntil, canFind, any;
import std.algorithm.sorting : sort;
import std.algorithm.iteration : uniq, map, reduce;
import std.algorithm.setops : setDifference;
import std.array : array, join;
import std.exception : ErrnoException;
import std.concurrency : Tid, setMaxMailboxSize, spawnLinked,
                         send, prioritySend, receiveTimeout, LinkTerminated,
                         thisTid, OnCrowding;
import std.typecons : Nullable;
import core.time : Duration;
import core.sys.posix.signal : sigaction, sigaction_t, SIGINT, SIGSEGV, SIGTERM, SIGHUP, SIGBUS, SA_RESTART, SA_RESETHAND;
import core.stdc.stdlib : exit;
import ui.multiBar : MultiBar, PositionalBar, BarStatus;
import btrfs.scanner : Progress, Status, DataType, Scanner;
import btrfs.database : Database, SqliteException;
import btrfs.fs : FilesystemState, FilesystemException, Tree;
import btrfs.header : FSID_SIZE, UUID_SIZE, ObjectID;

const maxMailBoxSize = 100000;
bool isAborting = false;
bool shouldAbort = false;
string[] errors;


void registerError(string device, string message)
{
    errors ~= device ~ ": " ~ message;
}

void registerError(const ref Progress progress, string message)
{
    registerError(progress.device, message);
}

bool printErrors()
{
    bool hadErrors = errors.length > 0;
    if (hadErrors)
    {
        stderr.writeln("Errors: ");
        foreach (error; errors)
        {
            stderr.writeln(" * " ~ error);
        }
        stderr.writeln();
        errors = [];
    }
    return hadErrors;
}

string formatProgress(ref PositionalBar bar, ref Progress progress)
{
    string output;
    string message = "";
    if (progress.status == Status.ABORTED || progress.status == Status.ERRORED)
    {
        message = progress.status == Status.ABORTED ? ", ABORTED!" : ", ERROR!";
    } else if (progress.status != Status.STARTED && progress.tree == 0)
    {
        message = bar.remainingTime;
    }

    if (progress.tree == 1 || progress.status == Status.STARTED)
    {
        output = format("%.2f%%%s", bar.percent, message);
    } else if (progress.tree == 0)
    {
        output = format("%s/%s (%.2f%%)%s", bar.index, bar.max, bar.percent, message);
    } else
    {
        output = format("%.2f%% (%d)%s", bar.percent, progress.tree, message);
    }

    return output;
}

void updateProgress(ref MultiBar!(string) multiBar, ref Progress progress)
{
    auto bar = multiBar.get(progress.device);
    switch (progress.status)
    {
        case Status.STARTED:
            if (bar.status != BarStatus.NONE)
            {
                bar = multiBar.reset(progress.device);
            }
            bar.index = 0;
            bar.max = progress.size;
            bar.suffix = { return formatProgress(bar, progress); };
            multiBar.start(bar);
            break;
        case Status.FINISHED:
        case Status.ERRORED:
        case Status.ABORTED:
            multiBar.finish(bar, (PositionalBar bar)
            {
                if (progress.status == Status.FINISHED)
                {
                    bar.goto_index(bar.max);
                } else
                {
                    bar.suffix = { return formatProgress(bar, progress); };
                }
            });
            break;
        default:
            bar.max = progress.size;
            multiBar.goto_index(bar, progress.progress);
    }
}

void processData(Database db, ref Progress data)
{
    if (data.dataType == DataType.Superblock)
    {
        db.storeSuperblock(data.deviceUuid, data.offset, data.superblock);
    } else if (data.dataType == DataType.Block)
    {
        auto commited = db.storeBlock(data.deviceUuid, data.offset, data.bytenr, data.block.superblock.fsid, data.block);
        if (data.tree > 0 || commited)
        {
            data.thread.send(data);
        }
    } else if (data.dataType == DataType.Ref)
    {
        Nullable!long owner;
        if (data.owner != ObjectID.INVALID)
        {
            owner = data.owner;
        }
        db.storeRef(data.deviceUuid, data.bytenr, owner, data.refInfo.child, data.refInfo.generation);
    } else if (data.dataType == DataType.Message)
    {
        registerError(data, data.message.to!string);
    }
    if (data.status != Status.STARTED && data.status != Status.WORKING)
    {
        db.commit();
    }
}

void processProgress(ref Progress progress, MultiBar!(string) progressBars, Database db)
{
    try
    {
        processData(db, progress);
    } catch (SqliteException e)
    {
        registerError(progress, e.msg);
        progress.status = Status.ERRORED;
        progress.thread.send(Status.ERRORED);
    }
    updateProgress(progressBars, progress);
}

void setupSignals()
{
    sigaction_t action = {};
    action.sa_flags = SA_RESTART;
    action.sa_handler = (int signal)
    {
        shouldAbort = true;
        if (signal != SIGINT)
        {
            stderr.write("\n\x1b[?25h");
        }
        if (signal == SIGTERM)
        {
            exit(-SIGTERM);
        }
    };
    sigaction(SIGINT, &action, null);
    action.sa_flags = SA_RESTART | SA_RESETHAND;
    sigaction(SIGSEGV, &action, null);
    sigaction(SIGBUS, &action, null);
    sigaction(SIGHUP, &action, null);
    sigaction(SIGTERM, &action, null);
}

void checkForAbort(ref string[Tid] threads, ulong lines)
{
    if (shouldAbort && !isAborting)
    {
        isAborting = true;
        foreach (thread, name; threads)
        {
            thread.prioritySend!Status(Status.ABORTED);
        }
        stderr.write("\x1b[" ~ lines.to!string ~ "F\x1b[2K");
        stderr.write("Aborting... Please wait!");
        stderr.write("\x1b[" ~ lines.to!string ~ "E");
    }
}

void scanDevices(string[] devices, ref string[Tid] threads)
{
    stderr.writeln("Scanning...");
    foreach (string device; devices)
    {
        auto tid = spawnLinked(&Scanner.scanDevice, device);
        threads[tid] = device;
    }
}

bool scanBlocks(FilesystemState[ubyte[FSID_SIZE]] filesystemStates, ulong[] blocks, Tree tree, ref string[Tid] threads)
{
    bool[ulong] found;
    blocks = blocks.sort.uniq.array;
    auto allBlocks = blocks;

    foreach (fsid, fs; filesystemStates)
    {
        auto currentBlocks = blocks;
        if (tree != Tree.none)
        {
            ulong[] roots = [];
            if (tree == Tree.all)
            {
                roots ~= fs.getTreeRoot(Tree.root);
                roots ~= fs.getTreeRoot(Tree.chunk);
                auto root = fs.getTreeRoot(Tree.log);
                if (root > 0)
                {
                    roots ~= root;
                }
            } else
            {
                auto root = fs.getTreeRoot(tree);
                if (root == 0)
                {
                    stderr.writeln(tree.to!string ~ " tree is empty!");
                    return false;
                }
                roots ~= root;
            }
            foreach (root; roots)
            {
                if (!currentBlocks.canFind(root))
                {
                    currentBlocks ~= root;
                    if (!allBlocks.canFind(root))
                    {
                        allBlocks ~= root;
                    }
                }
            }
        }

        try
        {
            foreach (block; currentBlocks)
            {
                auto offsetMirrors = fs.getOffsetInfo(block, fs.nodesize);
                foreach (offsetStripes; offsetMirrors)
                {
                    foreach (offsetInfo; offsetStripes)
                    {
                        found[block] = true;
                    }
                }
            }
        } catch (FilesystemException e)
        {
            stderr.writeln(fs.label ~ ": " ~ e.msg);
            return false;
        }

        auto missingDevices = fs.missingDeviceCount();
        if (missingDevices > 0)
        {
            registerError(fs.label, missingDevices.to!string ~ " device(s) are missing!");
        }
    }

    printErrors();
    if (found.length < allBlocks.length)
    {
        auto missing = allBlocks.sort.setDifference(found.keys.sort).map!(b => b.to!string);
        stderr.writeln("Didn't find block(s): " ~ missing.join(", "));
        return false;
    }
    if (filesystemStates.length <= 0)
    {
        return false;
    }
    stderr.writeln("Reading...");
    allBlocks = allBlocks.sort.uniq.array;
    foreach (fsid, fs; filesystemStates)
    {
        auto tid = spawnLinked(&Scanner.scanBlocks, cast(shared)fs, cast(immutable)allBlocks);
        threads[tid] = fs.label;
    }
    return true;
}

void processUpdates(Database db, string[Tid] threads)
{
    Tid[] finished;
    Tid[] terminated;
    auto progressBars = new MultiBar!string(threads.length, cast(int)threads.values.maxElement!("a.length").length);

    while (threads.keys.any!((t) => !terminated.canFind(t)))
    {
        checkForAbort(threads, progressBars.length);
        receiveTimeout(Duration.zero,
            (Progress progress)
            {
                if (!terminated.canFind(progress.thread))
                {
                    processProgress(progress, progressBars, db);
                    if (progress.status == Status.FINISHED ||
                        progress.status == Status.ERRORED ||
                        progress.status == Status.ABORTED)
                    {
                        progress.dataType = DataType.None;
                        progress.message[] = '\0';
                        progress.thread.send!Status(Status.FINISHED);
                        finished ~= progress.thread;
                    }
                }
            },

            (LinkTerminated e)
            {
                if (e.tid in threads && !finished.canFind(e.tid))
                {
                    auto name = threads[e.tid];
                    registerError(name, "Thread terminated unexpectedly!");
                    Progress progress;
                    progress.status = Status.ERRORED;
                    progress.tree = 1;
                    progress.dataType = DataType.None;
                    progressBars.finish(progressBars.get(name), (PositionalBar bar)
                    {
                        bar.suffix = { return formatProgress(bar, progress); };
                    });
                }
                terminated ~= e.tid;
            }
        );
    }
}

int main(string[] args)
{
    setupSignals();

    string databasePath;
    ulong[] blocks = [];
    Tree tree;

    try
    {
        auto optionInfo = getopt(args, config.required, "database|d", "Path to database for results", &databasePath,
                                 "block|b", "Block number to start", &blocks,
                                 "tree|t", "Tree to scan (all, root, chunk, log)", &tree);

        if (optionInfo.helpWanted)
        {
            defaultGetoptPrinter("Usage: " ~ args[0] ~ " [options] <devices...>", optionInfo.options);
            return 0;
        }
    } catch (Exception e)
    {
        stderr.writeln(e.msg);
        return -1;
    }

    if (args.length <= 1)
    {
        stderr.writeln("You need to specify atleast one device to scan!");
        return -1;
    }

    Database db;

    try
    {
        db = new Database(databasePath);
    } catch (SqliteException e)
    {
        stderr.writeln("Failed to open database '" ~ databasePath ~ "' for writing!");
        stderr.writeln(e.msg);
        // normally we would just return
        // return -2;
        // but there's some bug that causes GC spinlock to never be released
        exit(-2);
    }

    string[Tid] scannerThreads;
    setMaxMailboxSize(thisTid, maxMailBoxSize, OnCrowding.block);
    string[] devices = args[1..$].sort.uniq.array;
    if (blocks.length > 0 || tree != Tree.none)
    {
        FilesystemState[ubyte[FSID_SIZE]] filesystemStates = FilesystemState.create(devices, &registerError);
        if (tree == Tree.all)
        {
            const(ubyte[UUID_SIZE])[] deviceUUIDs;
            foreach (fsid, fs; filesystemStates)
            {
                deviceUUIDs ~= fs.getAllDeviceUUIDs();
            }
            db.clearRefs(deviceUUIDs);
        }
        if (!scanBlocks(filesystemStates, blocks, tree, scannerThreads))
        {
            return -3;
        }
    } else
    {
        scanDevices(devices, scannerThreads);
    }

    processUpdates(db, scannerThreads);
    stderr.writeln();

    try
    {
        db.destroy;
    } catch (Exception e)
    {
        stderr.writeln(e.msg);
    }

    if (printErrors())
    {
        stderr.writeln("Partial data saved to " ~ databasePath);
    } else
    {
        stderr.writeln("Completed! Data saved to " ~ databasePath);
    }

    return 0;
}
