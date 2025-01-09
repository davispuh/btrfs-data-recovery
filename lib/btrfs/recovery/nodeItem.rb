# frozen_string_literal: true

require_relative 'extentTree'
require_relative 'csumTree'
require_relative 'nodeItem'
require_relative 'leafItem'

module Btrfs
    module Recovery

        def self.recoverNodeItems(corruptedBlock, mirrorBlocks)
            corruptedItems = corruptedBlock.items.select { |item| item.corruption.isCorrupted? }
            return if corruptedItems.empty?

            foundItems = []
            maxOffset = corruptedBlock.size
            allBlocks = [corruptedBlock] + mirrorBlocks
            allBlocks.each do |block|
                items = []
                if block == corruptedBlock
                    id = corruptedItems.first.id
                else
                    items = block.items.take_while { |item| item.corruption.isValid? }
                    next if items.empty?
                    id = items.last.id + 1
                end

                currentOffset = Constants::HEADER_SIZE + Constants::NODE_ITEM_SIZE * id
                loop do
                    currentOffset = self.findAddItem(items, currentOffset, maxOffset, block, id)
                    break if currentOffset >= maxOffset
                    id += 1
                end
                foundItems += items
            end

            lastGoodItem = corruptedBlock.items[corruptedItems.first.id - 1]
            goodItems = {}
            foundItems.each do |item|
                next if item.key.offset <= lastGoodItem.key.offset
                if !goodItems.has_key?(item.key.offset) || item.generation > goodItems[item.key.offset].generation
                    goodItems[item.key.offset] = item
                end
            end

            goodItems = goodItems.values.sort_by { |item| item.key.offset }

            corruptedItems.each do |item|
                break if goodItems.empty?
                self.updateNodeItemHead(corruptedBlock, goodItems.shift)
            end
        end

        def self.updateNodeItemHead(block, item)
            data = self.packNodeItemHead(item)
            self.writeItemHead(block, item.id, data)
        end

        def self.packNodeItemHead(item)
            [item.key.objectid, item.key.type, item.key.offset, item.blockNumber, item.generation].pack("q<CQ<Q<Q<")
        end

    end
end
