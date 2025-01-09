# frozen_string_literal: true

module Btrfs
    module Recovery

        def self.recoverExtentItems(corruptedBlock, direction = :forward)
            raise "Unknown direction #{direction}" unless [:forward, :backward].include?(direction)

            corruptedItems = corruptedBlock.items.select { |item| item.corruption.offset? }
            return if corruptedItems.empty?

            direction = (direction == :forward ? 1 : -1)
            corruptedItems.reverse! if direction == -1

            isMetadataBlock = self.isMetadataBlock(corruptedBlock)

            corruptedItems.each do |item|
                otherItem = corruptedBlock.items[item.id - 1*direction]
                otherItem2 = corruptedBlock.items[item.id + 1*direction]

                next if otherItem.corruption.offset?

                origOffset = item.offset
                origSize = item.size

                fixed = false

                commonSizes = [24, 33, 37, 42, 50, 53, 66, 79, 90]
                commonSizes.each do |size|

                    if direction == -1
                        item.size = [[otherItem2.offset - otherItem.offset, 100].max, 200].min
                        item.offset = otherItem.offset + [otherItem.size, size].max
                    else
                        item.size = size
                        item.offset = otherItem.offset - item.size
                    end

                    next if item.offset < Constants::LEAF_ITEM_SIZE * corruptedBlock.itemCount ||
                            Constants::HEADER_SIZE + item.offset + item.size > corruptedBlock.size

                    itemTypes = []
                    if isMetadataBlock
                        itemTypes << Constants::METADATA_ITEM
                    else
                        itemTypes << Constants::EXTENT_ITEM
                    end
                    itemTypes << Constants::BLOCK_GROUP_ITEM if size == 24

                    itemTypes.each do |type|
                        item.key.type = type

                        offset = Constants::HEADER_SIZE + item.offset
                        data = corruptedBlock.buffer[offset, item.size]

                        Structures.parseExtentItem(item, data)

                        item.size = item.sizeRead
                        item.corruption.reset!
                        Structures.validateExtentItem!(item, corruptedBlock.header, nil, false)

                        fixed = !item.corruption.data?

                        break if fixed
                    end

                    break if fixed
                end

                if fixed
                    data = self.packLeafItemHead(item)
                    self.writeItemHead(corruptedBlock, item.id, data)
                else
                    item.corruption.offset = true
                    item.corruption.size = true
                    item.offset = origOffset
                    item.size = origSize
                end

            end
        end

        def self.fixExtentRefs(corruptedBlock, filesystemState = nil)
            corruptedBlock.items.each do |item|
                if item.corruption.data? &&
                   [Constants::EXTENT_ITEM, Constants::METADATA_ITEM].include?(item.key.type)
                    fixedItem = nil
                    if item.data.refs < item.data.inline.length
                        item.data.refs = item.data.inline.length
                        if Structures.validateExtentItem!(item, corruptedBlock.header)
                            fixedItem = item
                        end
                    end
                    if !item.corruption.head? && !filesystemState.nil? &&
                            filesystemState.respond_to?(:findItems) &&
                            filesystemState.respond_to?(:findExtentBackref)
                        item.data.inline.each do |inline|
                            case inline.type
                            when Constants::EXTENT_DATA_REF
                                extentDatas = filesystemState.findItems(Constants::EXTENT_DATA, inline.dataRef.objectid, inline.dataRef.offset)
                                found = extentDatas.any? { |extentData| extentData['owner'] == inline.dataRef.root && extentData['data'] == item.key.objectid }
                                if !found
                                    extentDatas = filesystemState.findExtentBackref(item.key.objectid)
                                    blockNumbers = extentDatas.map { |extentItem| extentItem['bytenr'] }.uniq
                                    if blockNumbers.length == 1
                                        inline.dataRef.root = extentDatas.first['owner']
                                        inline.dataRef.objectid = extentDatas.first['objectid']
                                        inline.dataRef.offset = extentDatas.first['offset']
                                        fixedItem = item
                                    elsif blockNumbers.length > 1
                                        raise 'Not implemented!'
                                    end
                                end
                            end
                        end
                    end
                    if fixedItem
                        data = self.writeExtentItem(fixedItem)
                        corruptedBlock.buffer[Constants::HEADER_SIZE + fixedItem.offset, data.size] = data
                    end
                end
            end
        end

        def self.writeExtentItem(item)
            data = [item.data.refs, item.data.generation, item.data.flags].pack("Q<Q<Q<")
            item.data.inline.each do |inline|
                data += [inline.type].pack("C")
                case inline.type
                when Constants::EXTENT_DATA_REF
                    data += [inline.dataRef.root, inline.dataRef.objectid,
                             inline.dataRef.offset, inline.dataRef.count].pack("Q<Q<Q<L<")
                when Constants::SHARED_DATA_REF
                    data += [inline.offset, inline.sharedRef.count].pack("Q<L<")
                when Constants::TREE_BLOCK_REF, Constants::SHARED_BLOCK_REF
                    data += [inline.offset].pack("Q<")
                else
                    raise 'Invalid extent inline!'
                end
            end
            data
        end

        def self.isMetadataBlock(block)

            block.items.each do |item|
                next unless item.isValid?
                if item.key.type == Constants::METADATA_ITEM
                    return true
                elsif item.key.type == Constants::EXTENT_ITEM
                    return false
                end
            end

            false
        end
    end
end
