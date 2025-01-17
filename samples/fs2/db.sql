
-- corrupted parent
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'688754bee23f4d71a152305d95839dc7',47480832,1,68452352,732551,X'2450100da3ab45e3a056bfa8a3236ee3',X'ed106cfa2affbbe0000000000000000000000000000000000000000000000000',2,297,2);
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'd5317c836597471c9e87bb1256fe4392',68452352,1,68452352,732551,X'2450100da3ab45e3a056bfa8a3236ee3',X'ed106cfa2affbbe0000000000000000000000000000000000000000000000000',2,297,2);

-- child
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'688754bee23f4d71a152305d95839dc7',1724729655296,1,2035062013952,732047,X'2450100da3ab45e3a056bfa8a3236ee3',X'1ee30228504d7270000000000000000000000000000000000000000000000000',2,320,1);
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'd5317c836597471c9e87bb1256fe4392',1724750626816,1,2035062013952,732047,X'2450100da3ab45e3a056bfa8a3236ee3',X'1ee30228504d7270000000000000000000000000000000000000000000000000',2,320,1);

-- child's child
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'688754bee23f4d71a152305d95839dc7',1709477560320,1,2019809918976,731818,X'2450100da3ab45e3a056bfa8a3236ee3',X'2b7b9d0131b09a75000000000000000000000000000000000000000000000000',2,94,0);
INSERT INTO blocks (deviceUuid, offset, isValid, bytenr, generation, fsid, csum, owner, nritems, level) VALUES (X'd5317c836597471c9e87bb1256fe4392',1709498531840,1,2019809918976,731818,X'2450100da3ab45e3a056bfa8a3236ee3',X'2b7b9d0131b09a75000000000000000000000000000000000000000000000000',2,94,0);

-- refs
INSERT INTO refs (deviceUuid, bytenr, owner, child, childGeneration, objectid, type, offset) VALUES (X'688754bee23f4d71a152305d95839dc7',68452352,2,2035062013952,732047,2299069083648,168,8192);
INSERT INTO refs (deviceUuid, bytenr, owner, child, childGeneration, objectid, type, offset) VALUES (X'd5317c836597471c9e87bb1256fe4392',68452352,2,2035062013952,732047,2299069083648,168,8192);
INSERT INTO refs (deviceUuid, bytenr, owner, child, childGeneration, objectid, type, offset) VALUES (X'688754bee23f4d71a152305d95839dc7',2035062013952,2,2019809918976,731818,2299077472256,168,8192);
INSERT INTO refs (deviceUuid, bytenr, owner, child, childGeneration, objectid, type, offset) VALUES (X'd5317c836597471c9e87bb1256fe4392',2035062013952,2,2019809918976,731818,2299077472256,168,8192);


INSERT INTO corruptBranches (deviceUuid, bytenr, child, objectid, type, offset) VALUES (X'688754bee23f4d71a152305d95839dc7',2035062013952,2019809918976,2299077472256,168,8192);
INSERT INTO corruptBranches (deviceUuid, bytenr, child, objectid, type, offset) VALUES (X'd5317c836597471c9e87bb1256fe4392',2035062013952,2019809918976,2299077472256,168,8192);

