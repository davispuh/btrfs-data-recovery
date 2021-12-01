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
                     WHERE isValid = 0 AND owner = 7'
21
```

Count how many generation mismatches there are

```
$ sqlite3 blocks.db 'SELECT COUNT(*) FROM blocks
                     JOIN refs ON blocks.deviceUuid = refs.deviceUuid
                     AND blocks.bytenr = refs.child
                     WHERE generation <> childGeneration'
28
```


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
