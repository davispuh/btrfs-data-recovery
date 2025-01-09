# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        MIN_DEVICE_SIZE = 10_000_000 # 10 MB

        def self.parseStripeData(io)
            fields = %i{devid offset devUuid}
            values = io.read(32).unpack("Q<Q<a16")
            OpenStruct.new(Hash[fields.zip(values)])
        end

        def self.parseChunkItem(item, data)
            io = StringIO.new(data)

            fields = %i{length owner stripeLen type ioAlign ioWidth sectorSize numStripes subStripes}
            values = io.read(48).unpack("Q<Q<Q<Q<L<L<L<S<S<")

            item.data = OpenStruct.new(Hash[fields.zip(values)])
            item.data.stripes = []
            item.data.numStripes.times do |n|
                item.data.stripes << self.parseStripeData(io)
            end

            item.sizeRead = io.tell
        end

        def self.isValidObjectId?(item, strict = true)
            item.key.objectid > 0 || (!strict && item.key.objectid.zero?)
        end

        def self.validateDevItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = item.key.objectid != Constants::ROOT_TREE_OBJECTID || item.key.offset < 1

            item.corruption.data = item.data.nil?
            return item.corruption.isValid? if item.corruption.data?

            isValid = item.data.devid > 0 &&
                      item.data.totalBytes > MIN_DEVICE_SIZE && item.data.bytesUsed > 0 &&
                      (item.data.ioAlign % header.block.sectorsize).zero? &&
                      (item.data.ioWidth % header.block.sectorsize).zero? &&
                      (header.block.sectorsize % item.data.sectorSize).zero? &&
                      item.data.fsid == header.fsid

            item.corruption.data = !isValid
            item.corruption.isValid?
        end

        def self.validateChunkItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = item.key.objectid != 256 ||
                                   !(item.key.offset % header.block.sectorsize).zero?

            item.corruption.data = item.data.nil?
            return item.corruption.isValid? if item.corruption.data?

            isValid = item.data.length > 0 && item.data.owner == Constants::EXTENT_TREE_OBJECTID &&
                      (item.data.stripeLen % item.data.sectorSize).zero? &&
                      (item.data.ioAlign % item.data.sectorSize).zero? &&
                      (item.data.ioWidth % item.data.sectorSize).zero? &&
                      (header.block.sectorsize % item.data.sectorSize).zero? &&
                      item.data.numStripes > 0 && item.data.numStripes < 200
                      item.data.subStripes >= 0 && item.data.subStripes < 50

            item.corruption.data = !isValid
            return item.corruption.isValid? unless isValid

            item.data.stripes.each do |stripe|
                if stripe.devid < 1
                    item.corruption.data = false
                    return item.corruption.isValid?
                end
            end

            item.corruption.isValid?
        end

    end
end
