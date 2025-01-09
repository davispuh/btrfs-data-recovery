# frozen_string_literal: true

require_relative 'extentTree'
require_relative 'csumTree'
require_relative 'nodeItem'
require_relative 'leafItem'

module Btrfs
    module Recovery

        MAX_TREE_OBJECTID = 10_000_000
        MAX_PERMUTATIONS = 1000

        def self.fixBlock(blocks, filesystemState = nil, tree = nil)
            return {} if blocks.empty?

            shouldTrySingle = blocks.length > 1
            blocks = self.addHeaderSwapped(blocks, filesystemState)
            blocks = self.sortMirrors(blocks)

            repairedBlock = nil
            candidateBlocks = Set.new

            maxGenerations = { }
            blocks.each do |block|
                next if block.header.owner > MAX_TREE_OBJECTID || block.header.owner < Constants::MIN_VALID_OBJECTID
                maxGenerations[block.header.owner] = [block.header.generation, maxGenerations[block.header.owner].to_i].max
            end

            tree = maxGenerations.max_by { |owner, generation| generation }.first if tree.nil?

            blocksPermutations = blocks.length.times.to_a.permutation.to_a.take(MAX_PERMUTATIONS)
            if shouldTrySingle
                blocks.each_with_index do |block, i|
                    blocksPermutations << [i] unless self.shouldReject(block, maxGenerations, tree)
                end
            end

            goodChecksums = Set.new
            [true, false].each do |throughout|
                blocksPermutations.each do |blockOrder|
                    orderedBlocks = blocks.values_at(*blockOrder)
                    next if self.shouldReject(orderedBlocks.first, maxGenerations, tree)

                    expectedCsum = orderedBlocks.first.header.csum
                    checksumMatch = orderedBlocks.first.checksumMatches?
                    goodChecksums << orderedBlocks.first.header.csum if checksumMatch
                    hasHeaderSwapped = orderedBlocks.first.headerSwapped

                    corruptedBlock = orderedBlocks.first.dup
                    corruptedBlock.validate!(filesystemState, throughout)

                    mirrorBlocks = orderedBlocks.drop(1)

                    block = self.repairBlock(corruptedBlock, mirrorBlocks, filesystemState, throughout)

                    if (!checksumMatch || hasHeaderSwapped) && block.isValid? && expectedCsum == block.header.csum
                        repairedBlock = block
                        break
                    elsif throughout
                        candidateBlocks << orderedBlocks.first
                        candidateBlocks << block
                    end
                end
                break if repairedBlock
            end

            resultBlock = repairedBlock ? repairedBlock : candidateBlocks.min_by { |block| block.getCorruptedItems.count - block.header.nritems }
            {
                block: resultBlock,
                successful: !!repairedBlock || resultBlock.isValid? && goodChecksums.any? { |checksum| resultBlock.header.csum == checksum }
            }
        end

        def self.shouldReject(block, maxGenerations, tree)
            return true if block.header.owner != tree

            return true if block.superblock && (block.header.fsid != block.superblock.fsid ||
                                                block.header.generation > block.superblock.generation)

            return true if block.header.generation < maxGenerations[block.header.owner]

            false
        end

        def self.repairBlock(corruptedBlock, mirrorBlocks, filesystemState = nil, throughout = true)
            self.copyItemHeaders(corruptedBlock, mirrorBlocks, filesystemState)

            if corruptedBlock.isLeaf?
                if corruptedBlock.header.owner == Constants::EXTENT_TREE_OBJECTID
                    self.recoverExtentItems(corruptedBlock, :forward) # :backward
                    self.fixExtentRefs(corruptedBlock, filesystemState)
                end

                self.recoverLeafItemSizes(corruptedBlock)
                self.recoverLeafItemKeys(corruptedBlock, mirrorBlocks)
                self.copyLeafItemData(corruptedBlock, mirrorBlocks, filesystemState, throughout)
                self.mirrorLeafItemData(corruptedBlock, mirrorBlocks, filesystemState, throughout)
                self.restoreLeafItems(corruptedBlock, mirrorBlocks, filesystemState, throughout)

                if corruptedBlock.header.owner == Constants::CSUM_TREE_OBJECTID
                    self.fixCsumData(corruptedBlock, filesystemState)
                end
            else
                self.recoverNodeItems(corruptedBlock, mirrorBlocks)
            end

            self.removeCorruptedItems(corruptedBlock)
            self.zeroFreeSpace(corruptedBlock)
            self.fixChecksum(corruptedBlock)

            corruptedBlock.reparse!
            corruptedBlock.validate!(filesystemState, throughout)

            corruptedBlock
        end

        # Sometimes block header is after 512 bytes
        def self.addHeaderSwapped(blocks, filesystemState = nil)
            extraBlocks = []
            blocks.each do |block|
                next if block.header.isValid?
                block = block.dup
                data = block.buffer[0, 512]
                block.buffer[0, 512] = block.buffer[512, 512]
                block.buffer[512, 512] = data
                block.headerSwapped = true
                block.validate!(filesystemState)
                extraBlocks << block
            end

            blocks + extraBlocks
        end

        def self.sortMirrors(blocks)
            blocks.sort_by { |b| [-b.header.generation, b.getCorruptedItems.count] }
        end

        def self.updateHeader(block)
            headerData = block.header.to_s
            block.buffer[0...headerData.length] = headerData
            block.header(true)
        end

        def self.copyItemHeaders(corruptedBlock, mirrorBlocks, filesystemState = nil)
            corruptedBlock.items.each do |item|
                if item.corruption.head?
                    mirrorBlocks.each do |block|
                        next if block.header.owner != corruptedBlock.header.owner ||
                                block.header.nritems != corruptedBlock.header.nritems ||
                                item.id >= block.items.length ||
                                block.items[item.id].corruption.head?

                        itemSize = corruptedBlock.isLeaf? ? Constants::LEAF_ITEM_SIZE : Constants::NODE_ITEM_SIZE

                        offset = Constants::HEADER_SIZE + itemSize * item.id
                        self.writeItemHead(corruptedBlock, item.id, block.buffer[offset, itemSize], filesystemState)

                        break
                    end
                end
            end
        end

        def self.removeCorruptedItems(block)
            lastValidItem = block.items.rindex { |item| item.isValid? }
            if !lastValidItem.nil? && block.header.nritems - lastValidItem > 1
                block.items.pop(block.header.nritems - lastValidItem - 1)
                block.header.nritems = block.items.length
            end
            self.updateHeader(block)
        end

        def self.zeroFreeSpace(block)
            if block.isNode?
                offset = Constants::HEADER_SIZE + Constants::NODE_ITEM_SIZE * (block.items.last.id + 1)
                block.buffer[offset..block.buffer.bytesize] = "\0" * (block.buffer.bytesize - offset)
            end
        end

        def self.fixChecksum(block)
            csum = block.getChecksum
            if csum
                block.buffer[0...csum.length] = csum
                block.header(true)
            end
        end

        def self.copyBlockToFile(device, offset, filesystemState, target, appendChecksum = true, pretend = false)
            raise "Target #{target} must be a Pathname!" unless target.is_a?(Pathname)
            filesystemState.usingDevice(device) do |io|
                io.seek(offset)
                blockData = io.read(filesystemState.superblock.nodesize)
                if appendChecksum
                    checksum = XXhash.xxh64(blockData).to_s(16)
                    ext = target.extname
                    newname = target.basename(ext).to_s + '_' + checksum + ext
                    target = target.dirname / newname
                end
                unless pretend
                    target.dirname.mkpath
                    target.binwrite(blockData)
                end
            end
            target
        end

        def self.copyBlock(sourceDevice, sourceOffset, filesystemState, targetDevice, targetOffset, pretend = false)
            copied = nil
            filesystemState.usingDevice(sourceDevice) do |source|
                source.seek(sourceOffset)
                filesystemState.usingDevice(targetDevice, true) do |target|
                    target.seek(targetOffset)
                    copied = 0
                    unless pretend
                        copied = ::IO.copy_stream(source, target, filesystemState.superblock.nodesize)
                    end
                end
            end
            copied
        end

        def self.swapHeader(targetDevice, targetOffset, filesystemState, pretend = false)
            written = 0
            filesystemState.usingDevice(targetDevice, true) do |target|
                target.seek(targetOffset)
                header = target.read(1024)
                header = IO.swapHeader(header)
                target.seek(targetOffset)
                unless pretend
                    written = target.write(header)
                end
            end
            written
        end

        def self.writeItemHead(block, id, data, filesystemState = nil)
            itemSize = block.isLeaf? ? Constants::LEAF_ITEM_SIZE : Constants::NODE_ITEM_SIZE

            offset = Constants::HEADER_SIZE + itemSize * id
            block.buffer[offset, itemSize] = data
            block.stream.seek(offset)

            if block.isLeaf?
                block.items[id] = Structures.parseLeafItem(Structures::LeafItem.new(id), block.stream)
            else
                block.items[id] = Structures.parseNodeItem(Structures::NodeItem.new(id), block.stream)
            end

            block.items[id].validate!(block.header, filesystemState)
        end

        def self.writeBlock(block, targetDevice, targetOffset, filesystemState)
            written = 0
            filesystemState.usingDevice(targetDevice, true) do |target|
                target.seek(targetOffset)
                StringIO.open(block.buffer) do |io|
                    written = ::IO.copy_stream(io, target)
                end
            end
            written
        end

        def self.findAddItem(items, currentOffset, maxOffset, block, id)
            currentOffset += 1
            itemSize = block.isLeaf? ? Constants::LEAF_ITEM_SIZE : Constants::NODE_ITEM_SIZE
            while currentOffset + itemSize <= maxOffset do
                block.stream.seek(currentOffset)
                if block.isLeaf?
                    item = Structures.parseLeafItemHead(Structures::LeafItem.new(id), block.stream)
                else
                    item = Structures.parseNodeItem(Structures::NodeItem.new(id), block.stream)
                end
                item.validate!(block.header)
                unless item.corruption.head?
                    items << item
                    break
                end

                currentOffset += 1
            end

            currentOffset
        end

    end
end
