# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        INODE_NODATASUM  = 1 << 0
        INODE_NODATACOW  = 1 << 1
        INODE_READONLY   = 1 << 2
        INODE_NOCOMPRESS = 1 << 3
        INODE_PREALLOC   = 1 << 4
        INODE_SYNC       = 1 << 5
        INODE_IMMUTABLE  = 1 << 6
        INODE_APPEND     = 1 << 7
        INODE_NODUMP     = 1 << 8
        INODE_NOATIME    = 1 << 9
        INODE_DIRSYNC    = 1 << 10
        INODE_COMPRESS   = 1 << 11

        INODE_MAX        = 1 << 15
        INODE_ROOT_ITEM_INIT = 1 << 31

        MAX_INDEX   = 100_000_000

        FT_UNKNOWN  = 0
        FT_REG_FILE = 1
        FT_DIR      = 2
        FT_CHRDEV   = 3
        FT_BLKDEV   = 4
        FT_FIFO     = 5
        FT_SOCK     = 6
        FT_SYMLINK  = 7
        FT_XATTR    = 8
        FT_MAX      = 9

         def self.readInode(io)
            fields = %i{generation transid size nbytes block_group
                        nlink uid gid mode rdev flags sequence reserved
                        atime ctime mtime otime}
            values = io.read(160).unpack("Q<Q<Q<Q<Q<L<L<L<L<Q<Q<Q<a32a12a12a12a12")

            data = OpenStruct.new(Hash[fields.zip(values)])
            data.atime = self.unpackTimespec(data.atime)
            data.ctime = self.unpackTimespec(data.ctime)
            data.mtime = self.unpackTimespec(data.mtime)
            data.otime = self.unpackTimespec(data.otime)

            data
        end

        def self.parseInodeItem(item, data)
            io = StringIO.new(data)
            item.data = self.readInode(io)
            item.sizeRead = io.tell
        end

        def self.parseInodeRef(item, data)
            io = StringIO.new(data)

            fields = %i{index length}
            values = io.read(10).unpack("Q<S<")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.data.name = io.read(item.data.length)
            item.data.name.force_encoding(Encoding::UTF_8)
            item.data.name.force_encoding(Encoding::ASCII_8BIT) unless item.data.name.valid_encoding?

            item.sizeRead = io.tell
        end

        def self.unpackTimespec(data)
            parts = data.unpack("Q<L<")
            Time.at(parts.first, parts.last, :nsec)
        end

        def self.parseDirItem(item, data)
            io = StringIO.new(data)

            fields = %i{location transid dataLength nameLength type}

            data = io.read(Constants::KEY_SIZE)
            values = [self.parseKey(data)]
            values += io.read(13).unpack("Q<S<S<C")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.data.name = io.read(item.data.nameLength)
            item.data.name.force_encoding(Encoding::UTF_8)
            item.data.name.force_encoding(Encoding::ASCII_8BIT) unless item.data.name.valid_encoding?
            item.data.xattrs = io.read(item.data.dataLength)&.unpack1("a*")

            item.sizeRead = io.tell
        end

        def self.parseDirIndex(item, data)
            self.parseDirItem(item, data)
        end

        def self.parseXattrItem(item, data)
            self.parseDirItem(item, data)
        end

        def self.parseRootItem(item, data)
            io = StringIO.new(data)

            fields = %i{inode generation rootDirId bytenr byteLimit bytesUsed
                        lastSnapshot flags refs dropProgress dropLevel level
                        generationV2 uuid parentUuid receivedUuid
                        ctransid otransid stransid rtransid
                        ctime otime stime rtime
                        reserved}

            values = [self.readInode(io)]
            values += io.read(279).unpack("Q<Q<Q<Q<Q<Q<Q<L<a17CCQ<a16a16a16Q<Q<Q<Q<a12a12a12a12a64")
            item.data = OpenStruct.new(Hash[fields.zip(values)])

            item.data.dropProgress = self.parseKey(item.data.dropProgress)
            item.data.ctime = self.unpackTimespec(item.data.ctime)
            item.data.otime = self.unpackTimespec(item.data.otime)
            item.data.stime = self.unpackTimespec(item.data.stime)
            item.data.rtime = self.unpackTimespec(item.data.rtime)

            item.sizeRead = io.tell
        end

        def self.isValidInodeData?(data, header)
            return false if data.nil?

            maxDate = Time.new(Time.now.year + 20)

            data.generation <= header.generation + MAX_GENERATION_LEEWAY &&
            data.generation > 0 &&
            data.nlink < MAX_ALLOWED_REFS &&
            (data.flags & (INODE_ROOT_ITEM_INIT - 1)) < INODE_MAX &&
            data.atime < maxDate &&
            data.ctime < maxDate &&
            data.mtime < maxDate &&
            data.otime < maxDate
        end

        def self.validateInodeItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true) || !item.key.offset.zero?

            isValid = self.isValidInodeData?(item.data, header)

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateInodeRef!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true) || item.key.offset.zero?

            isValid = item.data.index < MAX_INDEX && item.data.name.length > 0

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateDirItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true)

            item.corruption.data = item.data.nil?
            return item.corruption.isValid? if item.corruption.data?

            isValid = item.data.transid <= header.generation &&
                      item.data.type < FT_MAX

            if isValid && item.data.type != FT_XATTR
                isValid = item.data.location.objectid > 0 && [Constants::INODE_ITEM, Constants::ROOT_ITEM].include?(item.data.location.type)
            elsif isValid && item.data.type == FT_XATTR
                isValid = item.data.location.objectid.zero? &&
                          item.data.location.type.zero? &&
                          item.data.location.offset.zero? &&
                          item.data.xattrs.length > 0
            end

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateDirIndex!(item, header, filesystemState = nil, throughout = true)
            self.validateDirItem!(item, header, filesystemState, throughout)
        end

        def self.validateXattrItem!(item, header, filesystemState = nil, throughout = true)
            self.validateDirItem!(item, header, filesystemState, throughout)
        end

        def self.validateRootItem!(item, header, filesystemState, throughout)
            item.corruption.head = !self.isValidObjectId?(item, true) || !item.key.offset.zero?

            maxDate = Time.new(Time.now.year + 20)
            isValid = self.isValidInodeData?(item.data.inode, header) &&
                      item.data.generation <= header.generation + MAX_GENERATION_LEEWAY &&
                      item.data.generation > 0 &&
                      (item.data.bytenr % header.block.sectorsize).zero? &&
                      item.data.refs <= MAX_ALLOWED_REFS &&
                      item.data.ctime < maxDate &&
                      item.data.otime < maxDate &&
                      item.data.stime < maxDate &&
                      item.data.rtime < maxDate

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

    end
end
