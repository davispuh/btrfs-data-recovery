# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        # These needs to be tweaked
        MAX_ALLOWED_REFS = 1000
        MAX_EXTENT_REF_COUNT = 1000
        MAX_GENERATION_LEEWAY = 0

        MAX_FILE_SIZE = 30_000_000_000_000 # 30 TB

        MAX_BLOCK_GROUP_SIZE = 10**15
        MIN_SUBVOLUME_ID = 256

        EXTENT_INLINE    = 0
        EXTENT_REG       = 1
        EXTENT_PREALLOC  = 2
        EXTENT_MAX_TYPES = 3

        COMPRESSION_NONE = 0
        COMPRESSION_ZLIB = 1
        COMPRESSION_LZO  = 2
        COMPRESSION_ZSTD = 3
        COMPRESSION_MAX  = 4

        ENCRYPTION_NONE = 0
        ENCRYPTION_MAX  = 1

        ENCODING_NONE   = 0
        ENCODING_MAX    = 1

        BLOCK_GROUP_DATA     = 1 << 0
        BLOCK_GROUP_SYSTEM   = 1 << 1
        BLOCK_GROUP_METADATA = 1 << 2

        BTRFS_BLOCK_GROUP_RAID0  = 1 << 3
        BTRFS_BLOCK_GROUP_RAID1  = 1 << 4
        BTRFS_BLOCK_GROUP_DUP    = 1 << 5
        BTRFS_BLOCK_GROUP_RAID10 = 1 << 6
        BTRFS_BLOCK_GROUP_RAID5  = 1 << 7
        BTRFS_BLOCK_GROUP_RAID6  = 1 << 8

        BTRFS_BLOCK_GROUP_MASK  = 0x1FF
        BTRFS_BLOCK_GROUP_MAX   = (1 << 49) | (1 << 48) | (1 << 47)

        def self.parseExtentData(item, data)
            io = StringIO.new(data)

            fields = %i{generation size compression encryption encoding type}
            values = io.read(21).unpack("Q<Q<CCS<C")

            item.data = OpenStruct.new(Hash[fields.zip(values)])

            if item.data.type == EXTENT_INLINE
                item.data.data = io.read(item.data.size)
            else
                parts = io.read(32).unpack("Q<Q<Q<Q<")
                item.data.diskBytenr = parts[0]
                item.data.diskBytes = parts[1]
                item.data.offset = parts[2]
                item.data.bytes = parts[3]
            end

            item.sizeRead = io.tell
        end

        def self.parseExtentItem(item, data)
            io = StringIO.new(data)

            fields = %i{refs generation flags}
            values = io.read(24).unpack("Q<Q<Q<")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.data.inline = []
            item.data.extra = nil

            self.parseExtentInline(item, io) unless io.eof?
            item.sizeRead = io.tell
        end

        def self.parseExtentInline(item, io)
            inline = OpenStruct.new
            inline.type = io.readbyte

            case inline.type
            when Constants::EXTENT_DATA_REF
                inline.dataRef = self.parseExtentDataRef(io)
            when Constants::SHARED_DATA_REF
                inline.sharedRef = self.parseSharedDataRef(io)
            when Constants::TREE_BLOCK_REF, Constants::SHARED_BLOCK_REF
                inline.offset = io.read(8).unpack1("Q<")
            else
                io.seek(-1, ::IO::SEEK_CUR)
                item.data.extra = io.read
                io.seek(-item.data.extra.length, ::IO::SEEK_CUR)
                return
            end

            item.data.inline << inline

            self.parseExtentInline(item, io) unless io.eof?
        end

        def self.parseExtentDataRef(io)
            fields = %i{root objectid offset count}
            values = io.read(28).unpack("Q<Q<Q<L<")

            OpenStruct.new(Hash[fields.zip(values)])
        end

        def self.parseSharedDataRef(io)
            fields = %i{parent count}
            values = io.read(12).unpack("Q<L<")

            OpenStruct.new(Hash[fields.zip(values)])
        end

        def self.parseBlockGroupItem(item, data)
            fields = %i{used chunkObjectId flags}
            values = data.unpack("Q<Q<Q<")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.sizeRead = 24
        end

        def self.isValidExtentId?(item, header)
            item.key.objectid > 0 && (item.key.objectid % header.block.sectorsize).zero?
        end

        def self.validateExtentData!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true)

            item.corruption.data = item.data.nil?
            return item.corruption.isValid? if item.corruption.data?

            isValid = item.data.generation <= header.generation + MAX_GENERATION_LEEWAY &&
                      item.data.generation > 0 &&
                      item.data.size < MAX_FILE_SIZE &&
                      item.data.type < EXTENT_MAX_TYPES &&
                      item.data.compression < COMPRESSION_MAX &&
                      item.data.encryption < ENCRYPTION_MAX &&
                      item.data.encoding < ENCODING_MAX

            if isValid && item.data.type != EXTENT_INLINE
                isValid = (item.data.diskBytenr % header.block.sectorsize).zero? &&
                           item.data.diskBytes < MAX_FILE_SIZE &&
                           item.data.bytes < MAX_FILE_SIZE

                if isValid && item.data.compression == COMPRESSION_NONE &&
                              item.data.encryption == ENCRYPTION_NONE &&
                              item.data.encoding == ENCODING_NONE
                    isValid = (item.data.size == item.data.diskBytes) && (item.data.bytes <= item.data.diskBytes)
                end
            end

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateExtentItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidExtentId?(item, header)

            item.corruption.data = item.data.nil?
            return item.corruption.isValid? if item.corruption.data?

            isValid = item.data.refs <= MAX_ALLOWED_REFS &&
                      item.data.generation <= header.generation + MAX_GENERATION_LEEWAY
                      item.data.generation > 0

            item.data.inline.each do |inline|
                isValid = false unless self.isValidExtentInline?(inline, header)
            end
            isValid = isValid && item.data.extra.nil? && !item.data.refs.zero? && item.data.refs >= item.data.inline.length
            isValid = isValid && self.areExtentBackrefsValid?(item, filesystemState) if filesystemState && throughout

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateExtentDataRef!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true)
            item.corruption.data = !self.isValidExtentDataRef?(item, header)

            item.corruption.isValid?
        end

        def self.validateSharedDataRef!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !self.isValidObjectId?(item, true)
            item.corruption.data = item.data.count > MAX_EXTENT_REF_COUNT
            item.corruption.isValid?
        end

        def self.isValidExtentInline?(extentInline, header)
            validators = {
                Constants::EXTENT_DATA_REF  => :isValidExtentDataRef?,
                Constants::SHARED_DATA_REF  => :isValidSharedDataRef?,
                Constants::TREE_BLOCK_REF   => :isValidTreeBlockRef?,
                Constants::SHARED_BLOCK_REF => :isValidSharedBlockRef?
            }

            validator = validators[extentInline.type]
            if validator
                self.send(validator, extentInline, header)
            else
                false
            end
        end

        def self.areExtentBackrefsValid?(item, filesystemState)
            return true if item.data.inline.empty?

            allValid = true
            blocks = []
            item.data.inline.select { |inline| inline.type == Constants::SHARED_DATA_REF }
                            .each do |inline|
                allValid = false
                block = nil
                filesystemState.eachOffset(inline.sharedRef.parent) do |info, superblock, io|
                    data = io.read(superblock.nodesize)
                    block = self.parseBlock(data, superblock)
                    if block.header.isValid?
                        blocks << block
                        allValid = true
                        break
                    end
                end
                break unless allValid
            end

            return allValid unless allValid

            item.data.inline.each do |inline|
                next unless allValid
                case inline.type
                when Constants::EXTENT_DATA_REF
                    allValid = false
                    blocks.each do |block|
                        allValid = block.header.owner == inline.dataRef.root
                        break if allValid
                    end
                    next if allValid
                    if !filesystemState.nil? && filesystemState.respond_to?(:findItems)
                        allValid = false
                        extentDatas = filesystemState.findItems(Constants::EXTENT_DATA, inline.dataRef.objectid, inline.dataRef.offset)
                        allValid = extentDatas.any? { |extentData| extentData['owner'] == inline.dataRef.root && extentData['data'] == item.key.objectid }
                        break unless allValid
                    else
                        allValid ||= blocks.empty?
                    end
                    break unless allValid
                when Constants::TREE_BLOCK_REF
                    if !filesystemState.nil? && filesystemState.respond_to?(:isTreePresent?)
                        allValid = filesystemState.isTreePresent?(inline.offset)
                    end
                when Constants::SHARED_BLOCK_REF
                    if !filesystemState.nil?
                        allValid = false
                        self.eachBlock(inline.offset, filesystemState) do |block|
                            next unless block.isNode?
                            allValid = block.items.any? { |blockItem| blockItem.blockNumber == item.key.objectid }
                            break if allValid
                        end
                    end
                when Constants::SHARED_DATA_REF
                    # Already validated
                    next
                else
                    # Should never happen
                    allValid = false
                end
            end

            allValid
        end

        def self.validateBlockGroupItem!(blockGroupItem, header, filesystemState = nil, throughout = true)
            blockGroupItem.corruption.head = !self.isValidObjectId?(blockGroupItem, true)

            blockGroupItem.corruption.data = blockGroupItem.data.nil?
            return blockGroupItem.corruption.isValid? if blockGroupItem.corruption.data?

            isValid = blockGroupItem.data.used <= MAX_BLOCK_GROUP_SIZE &&
            blockGroupItem.data.flags < BTRFS_BLOCK_GROUP_MAX &&
            (blockGroupItem.data.flags & (BLOCK_GROUP_DATA | BLOCK_GROUP_SYSTEM | BLOCK_GROUP_METADATA)) > 0 &&
            ((blockGroupItem.data.flags & BTRFS_BLOCK_GROUP_MASK) >> 3).digits(2).sum == 1

            blockGroupItem.corruption.data = !isValid
            blockGroupItem.corruption.isValid?
        end

        def self.isValidExtentDataRef?(inline, header)
            if inline.respond_to?(:dataRef)
                data = inline.dataRef
            else
                data = inline.data
            end
            !data.root.nil? &&
                    (data.root == Constants::ROOT_TREE_OBJECTID ||
                    data.root == Constants::FS_TREE_OBJECTID ||
                    data.root >= MIN_SUBVOLUME_ID)
            !data.objectid.nil? &&
            !data.offset.nil? &&
            !data.count.nil? && data.count <= MAX_EXTENT_REF_COUNT
        end

        def self.isValidSharedDataRef?(inline, header)
            inline.sharedRef.parent > 0 && (inline.sharedRef.parent % header.block.sectorsize).zero? &&
            inline.sharedRef.count <= MAX_EXTENT_REF_COUNT
        end

        def self.isValidTreeBlockRef?(inline, header)
            inline.type == Constants::TREE_BLOCK_REF &&
            (
                (inline.offset >= Constants::ROOT_TREE_OBJECTID &&
                 inline.offset <= Constants::FREE_SPACE_TREE_OBJECTID) ||
                inline.offset >= MIN_SUBVOLUME_ID
            )
        end

        def self.isValidSharedBlockRef?(inline, header)
            inline.type == Constants::SHARED_BLOCK_REF &&
            inline.offset > 0 &&
            (inline.offset % header.block.sectorsize).zero?
        end

    end
end
