
CREATE TABLE IF NOT EXISTS superblocks(
    deviceUuid BLOB(16) NOT NULL,
    offset INTEGER NOT NULL,
    isValid INTEGER NOT NULL,
    label TEXT(256) NOT NULL,
    bytenr INTEGER NOT NULL,
    generation INTEGER NOT NULL,
    fsid BLOB(16) NOT NULL,
    numDevices INTEGER NOT NULL,
    csum BLOB(32) NOT NULL,
    csumType INTEGER NOT NULL,
    sectorsize INTEGER NOT NULL,
    nodesize INTEGER NOT NULL,
    root INTEGER NOT NULL,
    chunkRoot INTEGER NOT NULL,
    PRIMARY KEY (deviceUuid, offset)
) WITHOUT ROWID;


CREATE TABLE IF NOT EXISTS blocks(
    deviceUuid BLOB(16) NOT NULL,
    offset INTEGER NOT NULL,
    isValid INTEGER NOT NULL,
    bytenr INTEGER NOT NULL,
    generation INTEGER NOT NULL,
    fsid BLOB(16) NOT NULL,
    csum BLOB(32) NOT NULL,
    owner INTEGER NULL,
    nritems INTEGER NOT NULL,
    level INTEGER NOT NULL,
    PRIMARY KEY (deviceUuid, offset)
) WITHOUT ROWID;


CREATE TABLE IF NOT EXISTS refs(
    deviceUuid BLOB(16) NOT NULL,
    bytenr INTEGER NOT NULL,
    owner INTEGER NULL,
    child INTEGER NOT NULL,
    childGeneration INTEGER NULL,
    objectid INTEGER NULL,
    type INTEGER NULL,
    offset INTEGER NULL,
    PRIMARY KEY (deviceUuid, bytenr, child)
) WITHOUT ROWID;


CREATE TABLE IF NOT EXISTS keys(
    deviceUuid BLOB(16) NOT NULL,
    bytenr INTEGER NOT NULL,
    objectid INTEGER NOT NULL,
    type INTEGER NOT NULL,
    offset INTEGER NOT NULL,
    data INTEGER NULL,
    PRIMARY KEY (deviceUuid, type, offset, objectid, bytenr)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS corruptBranches(
    deviceUuid BLOB(16) NOT NULL,
    bytenr INTEGER NOT NULL,
    child INTEGER NULL,
    objectid INTEGER NOT NULL,
    type INTEGER NOT NULL,
    offset INTEGER NOT NULL,
    PRIMARY KEY (deviceUuid, bytenr)
) WITHOUT ROWID;

DROP INDEX IF EXISTS blocks.BlocksGeneration;
DROP INDEX IF EXISTS blocks.BlocksFS;
DROP INDEX IF EXISTS refs.RefsChildGeneration;
DROP INDEX IF EXISTS refs.RefsTree;
DROP INDEX IF EXISTS keys.KeysData;
