# BTRFS data recovery

Tools for data recovery when using BTRFS.

It allows to repair corrupted BTRFS to minimize data loss.

## Usage

`btrfs-scanner` is a program to collect info about BTRFS blocks in a database (SQLite).

```
Usage: btrfs-scanner [options] <devices...>
-d --database Required: Path to database for results
-b    --block           Block number to start
-t     --tree           Tree to scan (all, root, chunk, log)
-h     --help           This help information.
```

When `-t` option is not specified it will find all blocks
even unreferenced ones by scanning sequentially from start of disk till end.
But it doesn't determine if it's currently used (part of filesystem tree) or not.

So to create a database with full information need to run it twice, with both options.

```
$ btrfs-scanner -d blocks.db /dev/disk/by-id/ata-TOSHIBA_DT01ACA300 /dev/disk/by-id/ata-TOSHIBA_HDWD130
Scanning...
/dev/disk/by-id/ata-TOSHIBA_DT01ACA300 |################################| 119496187392/119496187392 (100.00%)
/dev/disk/by-id/ata-TOSHIBA_HDWD130    |################################| 119496187392/119496187392 (100.00%)

Completed! Data saved to blocks.db

$ btrfs-scanner -d blocks.db -t all /dev/disk/by-id/ata-TOSHIBA_DT01ACA300 /dev/disk/by-id/ata-TOSHIBA_HDWD130
Reading...
BtrfsDisk |################################| 100.00% (38862848)

Errors:
 * BtrfsDisk: Some errors for block (38862848)!

Partial data saved to blocks.db
```


Find out how many corrupted blocks there are (including unreferenced ones)

```
$ sqlite3 blocks.db 'SELECT COUNT(*) FROM blocks WHERE isValid = 0'
138
```

Find how many corrupted CSUM blocks there are counting only referenced blocks that are part of filesystem tree

```
$ sqlite3 blocks.db 'SELECT COUNT(*) FROM blocks
                     JOIN refs ON blocks.deviceUuid = refs.deviceUuid AND
                                  blocks.bytenr = refs.child AND
                                  blocks.generation = refs.childGeneration
                     WHERE isValid = 0 AND blocks.owner = 7'
21
```

Count how many generation mismatches there are

```
$ sqlite3 blocks.db 'SELECT COUNT(*) FROM blocks
                     JOIN refs ON blocks.deviceUuid = refs.deviceUuid AND
                                  blocks.bytenr = refs.child
                     WHERE generation <> childGeneration'
28
```

Find how many blocks need fixing

```
$ sqlite3 blocks.db 'SELECT COUNT(DISTINCT blocks.bytenr) FROM blocks
                     JOIN refs ON blocks.deviceUuid = refs.deviceUuid AND
                                  blocks.bytenr = refs.child
                     WHERE blocks.isValid = 0 OR generation <> childGeneration
                     GROUP BY blocks.fsid'
77
```

`btrfs-fixer.rb` is a program that can fix corrupted BTRFS blocks

```
Usage: btrfs-fixer.rb [options] <devices...>
    -d, --database DB                Path to database for automatic repair
    -t, --tree TREE                  Limit repair to specified tree (root, extent, chunk, dev, fs, csum, uuid)
    -c, --copy PATH                  Path where to copy block backup (default: ./backup/)
    -s, --superblock FILE            Path to superblock
    -b, --blocks IDs                 Block numbers
    -o, --output FILE                File where to write fixed block
        --[no-]repair                Repair
    -p, --[no-]print                 Print full info
    -q, --[no-]quiet                 Don't output info
    -x                               Swap first 1024 bytes
    -h, --help                       Show this message
```

Check how the filesystem repair would go

```
$ sudo btrfs-fixer.rb -d blocks.db /dev/disk/by-id/ata-TOSHIBA_DT01ACA300 /dev/disk/by-id/ata-TOSHIBA_HDWD130
[...]
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262696
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262696
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 [EXTENT_TREE] - Missing with generation 2262739
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 - Found good copy with generation 2262739 at 7036ea104dce48c6b6d566378ba54b03@19607633920
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 - Would copy backup to ./backup/21057110786048_098e5987adf94a37aad0dff0819c6588_19607633920_a9692a2766878bdc.bin
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 - Would fix by copying 21057110786048 from offset 19607633920 to 19607633920
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 [EXTENT_TREE] - Missing with generation 2262739
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 - Found corrupted copy with generation 2262739 at 7036ea104dce48c6b6d566378ba54b03@19607388160
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 - Skipping for now, will try fixing in next pass
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262698
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 - Found copy with swapped header with generation 2262739 at 098e5987adf94a37aad0dff0819c6588@19622002688
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 - Would copy backup to ./backup/21057125154816_7036ea104dce48c6b6d566378ba54b03_19622002688_bd58140e836ac4da.bin
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 - Would fix by copying 21057125154816 from offset 19622002688 to 19622002688
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 - Would swap block header at 19622002688
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 - Found good copy with generation 2262739 at 098e5987adf94a37aad0dff0819c6588@19593560064
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 - Would copy backup to ./backup/21057096712192_7036ea104dce48c6b6d566378ba54b03_19593560064_b196d838e132c76b.bin
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 - Would fix by copying 21057096712192 from offset 19593560064 to 19593560064
7036ea104dce48c6b6d566378ba54b03: Block 21057098481664 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057127841792 [EXTENT_TREE] - Generation mismatch, parent block 21057098416128 wants 2262696 but generation is 2262739
7036ea104dce48c6b6d566378ba54b03: Parent block 21057098416128 - Corrupted so skipping this and fixing that instead!
7036ea104dce48c6b6d566378ba54b03: Block 21057099137024 [EXTENT_TREE] - Missing with generation 2262739
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE - Found 295078 unreferenced blocks
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE [1/6] Block 21057100267520 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [67/295078] Checking unreferenced block 21056958808064
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 - Found good replacement block 21056958808064 with generation 2262738
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 - Would copy backup to ./backup/21057100267520_098e5987adf94a37aad0dff0819c6588_19597115392_c2e3c7e509a29d0a.bin
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 - Would fix by copying 21056958808064 from offset 19455655936 to 19597115392
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 [EXTENT_TREE] - Would set generation to 2262739 and update checksum to 0x98c20f6b
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE [2/6] Block 21057100726272 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [4675/295078] Checking unreferenced block 21058886713344
8aef11a9beb649ea9b2d7876611a39e5: [10199/295078] Checking unreferenced block 21057911881728
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 - Found good replacement block 21057911881728 with generation 2262704
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 - Would copy backup to ./backup/21057100726272_098e5987adf94a37aad0dff0819c6588_19597574144_d66cf82a2efcfa5e.bin
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 - Would fix by copying 21057911881728 from offset 20408729600 to 19597574144
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 [EXTENT_TREE] - Would set generation to 2262739 and update checksum to 0xb3b1974d
[...]
8aef11a9beb649ea9b2d7876611a39e5: CSUM_TREE - Found 328121 unreferenced blocks
8aef11a9beb649ea9b2d7876611a39e5: CSUM_TREE [1/2] Block 21057098481664 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [85/328121] Checking unreferenced block 21056905265152
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 - Found good replacement block 21056905265152 with generation 2262737
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 - Would copy backup to ./backup/21057098481664_098e5987adf94a37aad0dff0819c6588_19595329536_562705ed78a5ac89.bin
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 - Would fix by copying 21056905265152 from offset 19402113024 to 19595329536
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 [CSUM_TREE] - Would set generation to 2262739 and update checksum to 0xeb892d80
098e5987adf94a37aad0dff0819c6588: Block 21057103577088 [EXTENT_TREE] - Corrupted, expected checksum 0xa70630db but got 0xefc80998
8aef11a9beb649ea9b2d7876611a39e5: Block 21057103577088 - Trying to fix using 3 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057103577088 - Would copy backup to ./backup/21057103577088_098e5987adf94a37aad0dff0819c6588_19600424960_90c2053d69c1b72f.bin
098e5987adf94a37aad0dff0819c6588: Block 21057103577088 - Would fix it with correct checksum 0xa70630db
098e5987adf94a37aad0dff0819c6588: Block 21057105723392 [EXTENT_TREE] - Corrupted, expected checksum 0xe3ce09e9 but got 0x14d55849
7036ea104dce48c6b6d566378ba54b03: Block 21057105723392 [EXTENT_TREE] - Corrupted, expected checksum 0xe3ce09e9 but got 0x9465ee35
8aef11a9beb649ea9b2d7876611a39e5: Block 21057105723392 - Trying to fix using 2 candidate block(s)!
8aef11a9beb649ea9b2d7876611a39e5: Block 21057105723392 - Couldn't fix correctly, will try again using previous generation!
8aef11a9beb649ea9b2d7876611a39e5: [4003/295078] Checking unreferenced block 21060071653376
098e5987adf94a37aad0dff0819c6588: Block 21057105723392 - Would copy backup to ./backup/21057105723392_098e5987adf94a37aad0dff0819c6588_19602571264_5ccbdcdc864e5767.bin
098e5987adf94a37aad0dff0819c6588: Block 21057105723392 - Would fix it with correct checksum 0xe3ce09e9
7036ea104dce48c6b6d566378ba54b03: Block 21057105723392 - Would copy backup to ./backup/21057105723392_7036ea104dce48c6b6d566378ba54b03_19602571264_6e0d3d287bce4cef.bin
7036ea104dce48c6b6d566378ba54b03: Block 21057105723392 - Would fix it with correct checksum 0xe3ce09e9
098e5987adf94a37aad0dff0819c6588: Block 21057103855616 [CSUM_TREE] - Corrupted, expected checksum 0x93048e6b but got 0xe41f228f
7036ea104dce48c6b6d566378ba54b03: Block 21057103855616 [CSUM_TREE] - Corrupted, expected checksum 0x93048e6b but got 0x14526bac
8aef11a9beb649ea9b2d7876611a39e5: Block 21057103855616 - Trying to fix using 4 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057103855616 - Would copy backup to ./backup/21057103855616_098e5987adf94a37aad0dff0819c6588_19600703488_d6a9f364346f7646.bin
098e5987adf94a37aad0dff0819c6588: Block 21057103855616 - Would fix it with correct checksum 0x93048e6b
7036ea104dce48c6b6d566378ba54b03: Block 21057103855616 - Would copy backup to ./backup/21057103855616_7036ea104dce48c6b6d566378ba54b03_19600703488_8fe686b7579cdb5.bin
7036ea104dce48c6b6d566378ba54b03: Block 21057103855616 - Would fix it with correct checksum 0x93048e6b
098e5987adf94a37aad0dff0819c6588: Block 21057107017728 [ROOT_TREE] - Corrupted, expected checksum 0x9120eaee but got 0x35b2df28
7036ea104dce48c6b6d566378ba54b03: Block 21057107017728 [ROOT_TREE] - Corrupted, expected checksum 0x9120eaee but got 0xd00e16cf
8aef11a9beb649ea9b2d7876611a39e5: Block 21057107017728 - Trying to fix using 4 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057107017728 - Would copy backup to ./backup/21057107017728_098e5987adf94a37aad0dff0819c6588_19603865600_c01c6f5db7394750.bin
098e5987adf94a37aad0dff0819c6588: Block 21057107017728 - Would fix it with correct checksum 0x9120eaee
7036ea104dce48c6b6d566378ba54b03: Block 21057107017728 - Would copy backup to ./backup/21057107017728_7036ea104dce48c6b6d566378ba54b03_19603865600_ffec2f82921af42d.bin
7036ea104dce48c6b6d566378ba54b03: Block 21057107017728 - Would fix it with correct checksum 0x9120eaee
[...]
[70+8/82] Would have correctly fixed 70 block(s) and partially fixed 8 block(s) out of total 82 corrupted block(s)!
```

Perform actual repair of filesystem

```
$ sudo btrfs-fixer.rb --repair -d blocks.db /dev/disk/by-id/ata-TOSHIBA_DT01ACA300 /dev/disk/by-id/ata-TOSHIBA_HDWD130
[...]
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262696
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262696
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 [EXTENT_TREE] - Missing with generation 2262739
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 - Found good copy with generation 2262739 at 7036ea104dce48c6b6d566378ba54b03@19607633920
098e5987adf94a37aad0dff0819c6588: Block 21057110786048 [EXTENT_TREE] - Fixed! :)
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 [EXTENT_TREE] - Missing with generation 2262739
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 - Found corrupted copy with generation 2262739 at 7036ea104dce48c6b6d566378ba54b03@19607388160
098e5987adf94a37aad0dff0819c6588: Block 21057110540288 - Skipping for now, will try fixing in next pass
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262698
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 - Found copy with swapped header with generation 2262739 at 098e5987adf94a37aad0dff0819c6588@19622002688
7036ea104dce48c6b6d566378ba54b03: Block 21057125154816 [EXTENT_TREE] - Fixed! :)
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 - Found good copy with generation 2262739 at 098e5987adf94a37aad0dff0819c6588@19593560064
7036ea104dce48c6b6d566378ba54b03: Block 21057096712192 [CSUM_TREE] - Fixed! :)
7036ea104dce48c6b6d566378ba54b03: Block 21057098481664 [CSUM_TREE] - Missing with generation 2262739
7036ea104dce48c6b6d566378ba54b03: Block 21057127841792 [EXTENT_TREE] - Generation mismatch, parent block 21057098416128 wants 2262696 but generation is 2262739
7036ea104dce48c6b6d566378ba54b03: Parent block 21057098416128 - Corrupted so skipping this and fixing that instead!
7036ea104dce48c6b6d566378ba54b03: Block 21057098416128 [EXTENT_TREE] - Generation mismatch, wanted 2262739 but got 2262696
7036ea104dce48c6b6d566378ba54b03: Block 21057098416128 - Found corrupted copy with generation 2262739 at 098e5987adf94a37aad0dff0819c6588@19595264000
7036ea104dce48c6b6d566378ba54b03: Block 21057098416128 - Skipping for now, will try fixing in next pass
7036ea104dce48c6b6d566378ba54b03: Block 21057099137024 [EXTENT_TREE] - Missing with generation 2262739
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE - Found 295078 unreferenced blocks
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE [1/6] Block 21057100267520 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [67/295078] Checking unreferenced block 21056958808064
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 - Found good replacement block 21056958808064 with generation 2262738
098e5987adf94a37aad0dff0819c6588: Block 21057100267520 [EXTENT_TREE] - Partially Fixed! :)
8aef11a9beb649ea9b2d7876611a39e5: EXTENT_TREE [2/6] Block 21057100726272 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [10199/295078] Checking unreferenced block 21057911881728
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 - Found good replacement block 21057911881728 with generation 2262704
098e5987adf94a37aad0dff0819c6588: Block 21057100726272 [EXTENT_TREE] - Partially Fixed! :)
[...]
8aef11a9beb649ea9b2d7876611a39e5: CSUM_TREE - Found 328121 unreferenced blocks
8aef11a9beb649ea9b2d7876611a39e5: CSUM_TREE [1/2] Block 21057098481664 - Searching for previous block generation...
8aef11a9beb649ea9b2d7876611a39e5: [85/328121] Checking unreferenced block 21056905265152
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 - Found good replacement block 21056905265152 with generation 2262737
098e5987adf94a37aad0dff0819c6588: Block 21057098481664 [CSUM_TREE] - Partially Fixed! :)
098e5987adf94a37aad0dff0819c6588: Block 21057103577088 [EXTENT_TREE] - Corrupted, expected checksum 0xa70630db but got 0xefc80998
8aef11a9beb649ea9b2d7876611a39e5: Block 21057103577088 - Trying to fix using 3 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057103577088 - Fixed! :)
098e5987adf94a37aad0dff0819c6588: Block 21057105723392 [EXTENT_TREE] - Corrupted, expected checksum 0xe3ce09e9 but got 0x14d55849
7036ea104dce48c6b6d566378ba54b03: Block 21057105723392 [EXTENT_TREE] - Corrupted, expected checksum 0xe3ce09e9 but got 0x9465ee35
8aef11a9beb649ea9b2d7876611a39e5: Block 21057105723392 - Trying to fix using 2 candidate block(s)!
8aef11a9beb649ea9b2d7876611a39e5: Block 21057105723392 - Couldn't fix correctly, will try again using previous generation!
8aef11a9beb649ea9b2d7876611a39e5: [4003/295078] Checking unreferenced block 21060071653376
098e5987adf94a37aad0dff0819c6588: Block 21057105723392 - Fixed! :)
7036ea104dce48c6b6d566378ba54b03: Block 21057105723392 - Fixed! :)
098e5987adf94a37aad0dff0819c6588: Block 21057103855616 [CSUM_TREE] - Corrupted, expected checksum 0x93048e6b but got 0xe41f228f
7036ea104dce48c6b6d566378ba54b03: Block 21057103855616 [CSUM_TREE] - Corrupted, expected checksum 0x93048e6b but got 0x14526bac
8aef11a9beb649ea9b2d7876611a39e5: Block 21057103855616 - Trying to fix using 4 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057103855616 - Fixed! :)
7036ea104dce48c6b6d566378ba54b03: Block 21057103855616 - Fixed! :)
098e5987adf94a37aad0dff0819c6588: Block 21057107017728 [ROOT_TREE] - Corrupted, expected checksum 0x9120eaee but got 0x35b2df28
7036ea104dce48c6b6d566378ba54b03: Block 21057107017728 [ROOT_TREE] - Corrupted, expected checksum 0x9120eaee but got 0xd00e16cf
8aef11a9beb649ea9b2d7876611a39e5: Block 21057107017728 - Trying to fix using 4 candidate block(s)!
098e5987adf94a37aad0dff0819c6588: Block 21057107017728 - Fixed! :)
7036ea104dce48c6b6d566378ba54b03: Block 21057107017728 - Fixed! :)
[...]
[70+8/82] Correctly fixed 70 block(s) and partially fixed 8 block(s) out of total 82 corrupted block(s)!
```

Finally mount filesystem to copy data
```
$ sudo mount /dev/disk/by-id/ata-TOSHIBA_DT01ACA300 -o ro,rescue=nologreplay,subvolid=0
```
If mounting still fails then you can try additional options like rescue=ignorebadroots and others.

## Unlicense

![Copyright-Free](http://unlicense.org/pd-icon.png)

All text, documentation, code and files in this repository are in public domain (including this text, README).
It means you can copy, modify, distribute and include in your own work/code, even for commercial purposes, all without asking permission.

[About Unlicense](http://unlicense.org/)

## Contributing

Feel free to improve as you see.

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Export `.yaml` data files to binary `.dat` with `rake export`
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request


**Warning**: By sending pull request to this repository you dedicate any and all copyright interest in pull request (code files and all other) to the public domain. (files will be in public domain even if pull request doesn't get merged)

Also before sending pull request you acknowledge that you own all copyrights or have authorization to dedicate them to public domain.

If you don't want to dedicate code to public domain or if you're not allowed to (eg. you don't own required copyrights) then DON'T send pull request.
