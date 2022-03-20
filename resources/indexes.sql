
CREATE INDEX IF NOT EXISTS BlocksGeneration ON blocks (deviceUuid, bytenr, generation);
CREATE INDEX IF NOT EXISTS BlocksFS ON blocks (fsid, owner, bytenr, generation);
CREATE INDEX IF NOT EXISTS RefsChildGeneration ON refs (deviceUuid, child, childGeneration);
CREATE INDEX IF NOT EXISTS RefsTree ON refs (owner, deviceUuid);
