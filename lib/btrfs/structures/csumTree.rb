# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        def self.parseCsumItem(item, data)
            size = [[item.size, data.length].min, 4].max
            item.data = OpenStruct.new(:csums => data.unpack("a4" * (size / 4)))
            item.sizeRead = size
        end

        def self.validateCsumItem!(item, header, filesystemState = nil, throughout = true)
            item.corruption.head = item.key.objectid != Constants::EXTENT_CSUM_OBJECTID ||
                                   !(item.key.offset % header.block.sectorsize).zero?

            if filesystemState && throughout
                itemCsums = filesystemState.getBlockChecksums(header.block)[item.id]
                if itemCsums
                    item.corruption.data = false
                    itemCsums.each do |csumId, actualChecksums|
                        item.corruption.data = actualChecksums.none? { |actualChecksum| item.data.csums[csumId] == actualChecksum }
                        break if item.corruption.data?
                    end
                end
            else
                item.corruption.data = item.data.nil? || item.data&.csums.nil?
                item.data&.csums&.each do |csum|
                    if csum.bytes.all?(0) || csum.bytes.all?(0xFF)
                        item.corruption.data = true
                        break
                    end
                end
            end

            item.corruption.isValid?
        end

        class FilesystemState
            def getBlockChecksums(block)
                self.dataCache(:csums, block.object_id) do
                    Structures.getBlockChecksums(block, self)
                end
            end
        end

        def self.getBlockChecksums(block, filesystemState = nil)
            allChecksums = {}
            return allChecksums unless filesystemState

            filesystemState.eachOffset(block.items.first.key.offset) do |info, superblock, deviceIO|
                # we assume all items have same offset mapping
                # it seems to work fine for RAID1 but is probably wrong for other cases
                offsetDiff = info['logical'] - info['physical']
                block.items.each do |item|
                    allChecksums[item.id] ||= {}
                    next unless item.data
                    item.data.csums.each_with_index do |csum, csumId|
                        offset = item.key.offset - offsetDiff + csumId * block.sectorsize
                        deviceIO.seek(offset)
                        data = deviceIO.read(block.sectorsize)
                        allChecksums[item.id][csumId] ||= []
                        allChecksums[item.id][csumId] << Block.calculateChecksum(data, block.superblock.csumType)[0, csum.length]
                        allChecksums[item.id][csumId].uniq!
                    end
                end
            end

            allChecksums.each do |itemId, csums|
                csums.each do |csumId, actualChecksums|
                    actualChecksums.uniq!
                end
            end

            allChecksums
        end

    end
end
