# frozen_string_literal: true

require_relative 'header'
require_relative 'nodeItem'
require_relative 'leafItem'
require_relative 'block'
require_relative 'chunkTree'
require_relative 'extentTree'
require_relative 'csumTree'
require_relative 'fsTree'
require_relative 'freeSpace'
require 'ostruct'
require 'stringio'

module Btrfs
    module Structures

        class Key
            attr_accessor :objectid, :type, :offset

            def initialize(objectid, type, offset)
                @objectid = objectid
                @type = type
                @offset = offset
            end

            def ==(other)
                return false unless other.is_a?(Key)
                @objectid == other.objectid &&
                @type == other.type &&
                @offset == other.offset
            end

            def eql?(other)
                self == (other)
            end

            def hash
                [@objectid, @type, @offset].hash
            end

            def to_h
                {
                    'objectid' => @objectid,
                    'type'     => @type,
                    'offset'   => @offset
                }
            end
        end

        def self.loadBlock(io, superblock = nil, filesystemStates = nil, swapHeader = false)
            if swapHeader
                blockSize = Constants::BLOCK_SIZE
                blockSize = superblock.nodesize if superblock
                io = io.read(blockSize) if io.respond_to?(:read)
                io = IO.swapHeader(io)
            end
            block = self.parseBlock(io, superblock)
            block.headerSwapped = !!swapHeader

            filesystemState = nil
            if filesystemStates && filesystemStates.length == 1
                filesystemState = filesystemStates.values.first
            elsif filesystemStates
                filesystemState = filesystemStates[block.header.fsid]
            end

            block.validate!(filesystemState)
            block
        end

        def self.loadBlockAt(offset, device, filesystemState = nil, swapHeader = false)
            block = nil
            filesystemState.usingDevice(device) do |io|
                io.seek(offset)
                if swapHeader
                    io = io.read(filesystemState.superblock.nodesize)
                    io = IO.swapHeader(io)
                end
                block = self.parseBlock(io, filesystemState.superblock)
                block.device = device
                block.deviceOffset = offset
                block.headerSwapped = !!swapHeader
            end
            block
        end

        def self.eachBlock(blockNumbers, filesystemState, superblockOverride = nil, swapHeader = false, skipMirrors = false)
            seenBlocks = {}
            filesystemState.eachOffset(blockNumbers) do |info, superblock, io|
                bytenr = info['logical']
                next if skipMirrors && seenBlocks.key?(bytenr)
                next if seenBlocks.key?(bytenr) && seenBlocks[bytenr].include?(info['deviceUUID'])
                superblock = superblockOverride if superblockOverride
                blockData = io.read(superblock.nodesize)
                next if blockData.nil?
                block = self.loadBlock(blockData, superblock, { filesystemState.superblock.fsid => filesystemState }, swapHeader)
                block.device = io.path
                block.deviceOffset = info['physical']
                yield(block)
                seenBlocks[bytenr] ||= Set.new
                seenBlocks[bytenr] << info['deviceUUID']
            end
        end

        def self.loadBlocksByIDs(blockNumbers, filesystemStates, superblockOverride = nil, swapHeader = false)
            blocks = []
            filesystemStates.each do |fsid, state|
                self.eachBlock(blockNumbers, state, superblockOverride, swapHeader, false) do |block|
                    blocks << block
                end
            end
            blocks
        end

        def self.parseBlock(io, superblock = nil)
            data = io
            if io.respond_to?(:read)
                blockSize = Constants::BLOCK_SIZE
                blockSize = superblock.nodesize if superblock
                data = io.read(blockSize).to_s
            end
            Block.new(data, superblock)
        end

        def self.parseKey(data)
            Key.new(*data.unpack("q<CQ<"))
        end

        def self.parseHeader(blockBuffer, block)
            fields = %i{csum fsid bytenr flags chunkTreeUUID generation owner nritems level}
            values = blockBuffer[0, Constants::HEADER_SIZE].unpack("A32a16Q<B64a16Q<qL<C")

            values[0] = "\0\0\0\0" if values[0].empty?

            fields << 'block'
            values << block

            Header.new(Hash[fields.zip(values)])
        end

        def self.parseNodeItem(item, io)
            data = io.read(Constants::KEY_SIZE)
            return item if data.nil?
            item.key = self.parseKey(data)

            data = io.read(16)
            return item if data.nil?

            values = data.unpack("Q<Q<")
            item.blockNumber = values.first
            item.generation = values.last

            item
        end

        def self.parseLeafItem(item, io)
            self.parseLeafItemHead(item, io)

            if !item.offset.nil?
                io.seek(Constants::HEADER_SIZE + item.offset)
                data = io.read(item.size)
                self.parseLeafItemData(item, data) unless data.to_s.empty?
            end

            item
        end

        def self.parseLeafItemHead(item, io)
            data = io.read(Constants::KEY_SIZE)
            return item if data.nil?
            item.key = self.parseKey(data)

            data = io.read(8)
            return item if data.nil?

            values = data.unpack("L<L<")
            item.offset = values.first
            item.size = values.last

            item
        end

        def self.parseLeafItemData(item, data)
            case item.key.type
            when Constants::INODE_ITEM
                self.parseInodeItem(item, data)
            when Constants::INODE_REF
                self.parseInodeRef(item, data)
            when Constants::XATTR_ITEM
                self.parseXattrItem(item, data)
            when Constants::DIR_ITEM
                self.parseDirItem(item, data)
            when Constants::DIR_INDEX
                self.parseDirIndex(item, data)
            when Constants::EXTENT_DATA
                self.parseExtentData(item, data)
            when Constants::EXTENT_CSUM
                self.parseCsumItem(item, data)
            when Constants::ROOT_ITEM
                self.parseRootItem(item, data)
            when Constants::EXTENT_ITEM, Constants::METADATA_ITEM
                self.parseExtentItem(item, data)
            when Constants::EXTENT_DATA_REF
                io = StringIO.new(data)
                item.data = self.parseExtentDataRef(io)
                item.sizeRead = io.tell
            when Constants::SHARED_DATA_REF
                io = StringIO.new(data)
                item.data = OpenStruct.new
                item.data.count = io.read(4).unpack1("L<")
                item.sizeRead = io.tell
            when Constants::BLOCK_GROUP_ITEM
                self.parseBlockGroupItem(item, data)
            when Constants::DEV_ITEM
                self.parseDevItem(data, item)
            when Constants::CHUNK_ITEM
                self.parseChunkItem(item, data)
            when Constants::UNTYPED
                if item.key.objectid == Constants::FREE_SPACE_OBJECTID
                    self.parseFreeSpaceHeader(item, data)
                end
            else
                io = StringIO.new(data)
                item.data = io.read(item.size)
                item.sizeRead = io.tell
            end

            item
        end

        def self.parseItems(count, blockBuffer, type = :leaf)
            io = StringIO.new(blockBuffer)

            itemSize = (type == :leaf ? Constants::LEAF_ITEM_SIZE : Constants::NODE_ITEM_SIZE)

            items = []
            count.times do |id|
                io.seek(Constants::HEADER_SIZE + id * itemSize)
                if type == :leaf
                    item = self.parseLeafItem(LeafItem.new(id), io)
                else
                    item = self.parseNodeItem(NodeItem.new(id), io)
                end

                items << item
            end

            items
        end

    end
end
