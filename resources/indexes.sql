
CREATE INDEX IF NOT EXISTS BlocksGeneration ON blocks (deviceUuid, bytenr, generation);
CREATE INDEX IF NOT EXISTS RefsChildGeneration ON refs (deviceUuid, child, childGeneration);
