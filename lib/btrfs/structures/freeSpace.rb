# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        MAX_FREE_SPACE_BITMAPS = 10_000

        def self.parseFreeSpaceHeader(item, data)
            io = StringIO.new(data)

            fields = %i{location generation entries bitmaps}

            data = io.read(Constants::KEY_SIZE)
            values = [self.parseKey(data)]
            values += io.read(24).unpack("Q<Q<Q<")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.sizeRead = io.tell
        end

        def self.validateFreeSpaceHeader!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = !(item.key.offset % header.block.sectorsize).zero?

            isValid = item.data.generation <= header.generation + MAX_GENERATION_LEEWAY &&
                      item.data.generation > 0 &&
                      item.data.bitmaps < MAX_FREE_SPACE_BITMAPS &&
                      item.data.location.objectid > 0 &&
                      item.data.location.type == Constants::INODE_ITEM &&
                      item.data.location.offset.zero?

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

    end
end
