# frozen_string_literal: true

require_relative 'extentTree'
require_relative 'csumTree'
require_relative 'nodeItem'
require_relative 'leafItem'

module Btrfs
    module Recovery

        def self.recoverLeafItemSizes(corruptedBlock)
            corruptedBlock.items.each do |item|
                if !item.corruption.offset? && item.corruption.size?
                    item.size = item.sizeRead
                    data = self.packLeafItemHead(item)
                    self.writeItemHead(corruptedBlock, item.id, data)
                end
            end
        end

        def self.recoverLeafItemKeys(corruptedBlock, mirrorBlocks)
            corruptedItems = corruptedBlock.items.select { |item| item.corruption.head? }
            return if corruptedItems.empty?

            mirrorBlocksItems = []
            mirrorBlocks.each do |block|
                items = block.items.take_while { |item| !item.corruption.head? }
                next if items.empty?

                maxOffset = self.findMinLeafOffset(block.items)
                id = items.last.id + 1
                currentOffset = Constants::HEADER_SIZE + Constants::LEAF_ITEM_SIZE * id
                loop do
                    currentOffset = self.findAddItem(items, currentOffset, maxOffset, block, id)
                    break if currentOffset >= maxOffset
                    id += 1
                end
                mirrorBlocksItems << items
            end

            foundItems = []
            maxOffset = self.findMinLeafOffset(corruptedBlock.items)
            currentOffset = Constants::HEADER_SIZE + Constants::LEAF_ITEM_SIZE * corruptedItems.first.id
            corruptedItems.each do |item|
                currentOffset = self.findAddItem(foundItems, currentOffset, maxOffset, corruptedBlock, item.id)
            end

            corruptedItems.each do |item|
                fixed = self.fixLeafItemKey(foundItems, item, corruptedBlock)
                unless fixed
                    mirrorBlocksItems.each do |mirrorItems|
                        fixed = self.fixLeafItemKey(mirrorItems, item, corruptedBlock)
                        break if fixed
                    end
                end

                if fixed
                    data = self.packLeafItemHead(item)
                    self.writeItemHead(corruptedBlock, item.id, data)
                end
            end
        end

        def self.copyLeafItemData(corruptedBlock, mirrorBlocks, filesystemState = nil, throughout = true)
            corruptedBlock.items.each do |corruptedItem|
                if corruptedItem.corruption.data? && !corruptedItem.corruption.offset?
                    mirrorBlocks.each do |block|
                        block.items.each do |itemCandidate|
                            if itemCandidate.isValid? &&
                               itemCandidate.key.type == corruptedItem.key.type &&
                               itemCandidate.key.objectid == corruptedItem.key.objectid &&
                               itemCandidate.key.offset == corruptedItem.key.offset
                                item = itemCandidate.dup
                                item.id = corruptedItem.id
                                corruptedBlock.items[corruptedItem.id] = item
                                candidateOffset = Constants::HEADER_SIZE + item.offset
                                itemOffset = Constants::HEADER_SIZE + corruptedItem.offset
                                data = block.buffer[candidateOffset, item.size]
                                corruptedBlock.buffer[itemOffset, item.size] = data

                                Structures.parseLeafItemData(item, data)
                                item.validate!(corruptedBlock.header, filesystemState, throughout)
                                break if item.isValid?
                            end
                        end
                        break if corruptedBlock.items[corruptedItem.id].isValid?
                    end
                end
            end

            # We need to revalidate because we don't check for overlaps
            # meaning that while fixing one item we overwrite another
            corruptedBlock.items(true)
            corruptedBlock.validate!(filesystemState, false)
        end

        def self.mirrorLeafItemData(corruptedBlock, mirrorBlocks, filesystemState = nil, throughout = true)
            corruptedBlock.items.each do |item|
                if item.corruption.data? && !item.corruption.offset?
                    offset = Constants::HEADER_SIZE + item.offset
                    itemClone = item.dup
                    mirrorBlocks.each do |block|
                        data = block.buffer[offset, itemClone.size]
                        next if data.nil? || data == corruptedBlock.buffer[offset, itemClone.size]
                        Structures.parseLeafItemData(itemClone, data)
                        itemClone.validate!(corruptedBlock.header, filesystemState, throughout)
                        unless itemClone.corruption.data?
                            corruptedBlock.items[itemClone.id] = itemClone
                            corruptedBlock.buffer[offset, itemClone.size] = data
                            break
                        end
                    end
                end
            end

            # We need to revalidate because we don't check for overlaps
            # meaning that while fixing one item we overwrite another
            corruptedBlock.items(true)
            corruptedBlock.validate!(filesystemState, throughout)
        end

        def self.restoreLeafItems(corruptedBlock, mirrorBlocks, filesystemState = nil, throughout = true)
            fixFromIndex = corruptedBlock.items.index {|item| !item.isValid? }
            if fixFromIndex.to_i > 0
                fixFromIndex -= 1
                lastGoodItem = corruptedBlock.items[fixFromIndex - 1]
                mirrorBlocks.each do |block|
                    next if !block.isValid? || !block.isLeaf? || block.header.owner != corruptedBlock.header.owner
                    itemMatch = nil
                    block.items.each do |item|
                        next if item.key.objectid < lastGoodItem.key.objectid ||
                                (item.key.objectid == lastGoodItem.key.objectid &&
                                    (item.key.type < lastGoodItem.key.type ||
                                    (item.key.type == lastGoodItem.key.type &&
                                        item.key.offset < lastGoodItem.key.offset)))
                        itemMatch = item
                        break
                    end
                    next if itemMatch.nil?
                    sourceIndex = itemMatch.id
                    sourceIndex += 1 if itemMatch.key.objectid == lastGoodItem.key.objectid &&
                                        itemMatch.key.type == lastGoodItem.key.type &&
                                        itemMatch.key.offset == lastGoodItem.key.offset

                    count = [corruptedBlock.items.length - fixFromIndex, block.items.length - sourceIndex].min
                    count.times do |i|
                        item = block.items[sourceIndex+i].dup
                        item.id = fixFromIndex + i
                        sourceOffset = Constants::HEADER_SIZE + item.offset
                        item.offset = corruptedBlock.items[item.id - 1].offset - item.size
                        corruptedBlock.buffer[Constants::HEADER_SIZE + item.offset, item.size] = block.buffer[sourceOffset, item.size]
                        data = self.packLeafItemHead(item)
                        self.writeItemHead(corruptedBlock, item.id, data)
                    end
                    break unless count.zero?
                end
                corruptedBlock.items
            end
            corruptedBlock.validate!(filesystemState, throughout)
        end

        def self.packLeafItemHead(item)
            [item.key.objectid, item.key.type, item.key.offset, item.offset, item.size.to_i].pack("Q<CQ<L<L<")
        end

        def self.findMinLeafOffset(items)
            minOffset = Constants::MAX_ITEMS * Constants::LEAF_ITEM_SIZE
            items.reverse.each do |item|
                if item.corruption.offset?
                    minOffset = [minOffset, (item.id + 1) * Constants::LEAF_ITEM_SIZE].min
                    break
                end
            end

            minOffset
        end

        def self.fixLeafItemKey(otherItems, item, block)
            otherItems.each_with_index do |otherItem, i|
                if otherItem.offset == item.offset
                    item.key = otherItem.key
                    if item.size != otherItem.size
                        item.size = otherItem.size
                        offset = Constants::HEADER_SIZE + item.offset
                        data = block.buffer[offset, item.size]
                        Structures.parseLeafItemData(item, data)
                        item.validate!(block.header)
                    end
                    otherItems.delete_at(i)

                    return true
                end
            end

            false
        end

    end
end
