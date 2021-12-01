
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
    child INTEGER NOT NULL,
    childGeneration INTEGER NOT NULL,
    PRIMARY KEY (deviceUuid, bytenr, child)
) WITHOUT ROWID;

DROP INDEX IF EXISTS blocks.BlocksGeneration;
DROP INDEX IF EXISTS refs.RefsChildGeneration;
