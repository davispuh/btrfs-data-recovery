module btrfs.database;

import std.conv : to;
import d2sqlite3 : DB = Database, Statement, SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE;
import std.typecons : Nullable;
public import d2sqlite3 : SqliteException;
import btrfs.header : UUID_SIZE, FSID_SIZE, ObjectID;
import btrfs.superblock : Superblock;
import btrfs.block : Block;
import btrfs.items : Key;

class Database
{
private:
    DB db;
    Statement superblock;
    Statement block;
    Statement refs;
    Statement keys;
    Statement corruptBranches;
    ulong count = 0;
    const commitOn = 20000;
public:
    this(string path, int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    {
        this.db = DB(path, flags);
        db.run(import("config.sql"));
        db.run(import("tables.sql"));

        this.superblock = db.prepare(q{
            INSERT OR REPLACE INTO superblocks (deviceUuid, offset, isValid, label, bytenr, generation, fsid, numDevices, csum, csumType, sectorsize, nodesize, root, chunkRoot)
            VALUES (:deviceUuid, :offset, :isValid, :label, :bytenr, :generation, :fsid, :numDevices, :csum, :csumType, :sectorsize, :nodesize, :root, :chunkRoot)
        });

        this.block = db.prepare(q{
            INSERT OR REPLACE INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level)
            VALUES (:deviceUuid, :offset, :isValid, :bytenr, :generation, :fsid, :csum, :owner, :nritems, :level)
        });

        this.refs = db.prepare(q{
            INSERT OR REPLACE INTO refs (deviceUuid, bytenr, owner, child, childGeneration, objectId, type, offset)
            VALUES (:deviceUuid, :bytenr, :owner, :child, :childGeneration, :objectId, :type, :offset)
        });

        this.keys = db.prepare(q{
            INSERT OR REPLACE INTO keys (deviceUuid, bytenr, objectid, type, offset, data)
            VALUES (:deviceUuid, :bytenr, :objectid, :type, :offset, :data)
        });

        this.corruptBranches = db.prepare(q{
            INSERT OR REPLACE INTO corruptBranches (deviceUuid, bytenr, child, objectid, type, offset)
            VALUES (:deviceUuid, :bytenr, :child, :objectid, :type, :offset)
        });

        this.db.begin();
    }

    ~this()
    {
        this.db.commit();
        db.run(import("indexes.sql"));
        db.run(import("optimize.sql"));
    }

    void clearRefs(const(ubyte[UUID_SIZE])[] deviceUuids)
    {
        db.execute("DELETE FROM refs WHERE deviceUuid IN (:uuids)", deviceUuids);
    }

    void clearKeys(const(ubyte[UUID_SIZE])[] deviceUuids)
    {
        db.execute("DELETE FROM keys WHERE deviceUuid IN (:uuids)", deviceUuids);
    }

    bool storeSuperblock(ubyte[UUID_SIZE] deviceUuid, size_t offset, const ref Superblock superblock)
    {
        // deviceUuid, offset, isValid, label, bytenr, generation, fsid, numDevices, csum, csumType, sectorsize, nodesize, root, chunkRoot
        this.superblock.inject(deviceUuid, offset, superblock.isValid(),
                               superblock.label.to!string, superblock.bytenr, superblock.generation,
                               superblock.fsid, superblock.numDevices, superblock.csum, superblock.csumType,
                               superblock.sectorsize, superblock.nodesize, superblock.root, superblock.chunkRoot);

        return this.maybeCommit();
    }

    bool storeBlock(ubyte[UUID_SIZE] deviceUuid, size_t offset, ulong bytenr, ubyte[FSID_SIZE] fsid, const ref Block block)
    {
        // deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level
        this.block.inject(deviceUuid, offset, block.isValid(),
                          cast(long)bytenr, cast(long)block.generation, fsid,
                          block.csum, block.owner, block.nritems, block.level);

        return this.maybeCommit();
    }

    bool storeRef(ubyte[UUID_SIZE] deviceUuid, ulong bytenr, Nullable!long owner, ulong child, ulong generation, const ref Key key)
    {
        Nullable!long childGeneration;
        Nullable!long objectid;
        Nullable!long type;
        Nullable!long offset;
        if (generation <= long.max)
        {
            childGeneration = generation;
        }
        if (key.objectid != 0 &&
            key.type != 0 &&
            key.offset != 0)
        {
            if (key.objectid <= long.max)
            {
                objectid = key.objectid;
            }
            if (key.type <= long.max)
            {
                type = key.type;
            }
            if (key.offset <= long.max)
            {
                offset = key.offset;
            }
        }
        if (child <= long.max) // ignore too large child bytenr
        {
            // deviceUuid, bytenr, child, childGeneration
            this.refs.inject(deviceUuid, bytenr, owner, child, childGeneration, objectid, type, offset);
            return this.maybeCommit();
        }
        return false;
    }

    void storeKeys(ubyte[UUID_SIZE] deviceUuid, ulong bytenr, const ref Key key, Nullable!long data)
    {
        // can't store bigger values, for now just ignore them
        if (key.objectid <= long.max &&
            key.type <= long.max &&
            key.offset <= long.max)
        {
            // deviceUuid, bytenr, objectid, type, offset
            this.keys.inject(deviceUuid, cast(long)bytenr, key.objectid, key.type, key.offset, data);
        }
    }

    void storeBranch(ubyte[UUID_SIZE] deviceUuid, ulong bytenr, const ref Key key, ulong child)
    {
        Nullable!long childBlock;
        if (child > 0)
        {
            childBlock = child;
        }

        ulong objectid = key.objectid;
        if (objectid > long.max)
        {
            objectid = 0;
        }

        ulong type = key.type;
        if (type > long.max)
        {
            type = 0;
        }

        ulong offset = key.offset;
        if (offset > long.max)
        {
            offset = 0;
        }

        // deviceUuid, bytenr, child, objectid, type, offset
        this.corruptBranches.inject(deviceUuid, cast(long)bytenr, childBlock, objectid, type, offset);
    }

    void commit()
    {
        this.db.commit();
        this.db.begin();
    }

    bool maybeCommit()
    {
        this.count++;
        if (this.count >= commitOn)
        {
            this.commit();
            this.count = 0;
            return true;
        }

        return false;
    }

}
