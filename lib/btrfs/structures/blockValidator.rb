# frozen_string_literal: true

module Btrfs
    module Structures
        MAX_DATA_SIZE = 7800
        MAX_BLOCK = 0x1000000000000

        def self.validateTree(block, filesystemStates)
            return block.isValid? unless block.isNode?
            blockNumbers = block.items.map { |item| item.blockNumber }
            blocks = Structures.loadBlocksByIDs(blockNumbers, filesystemStates)
            blocks.each do |block|
                return block unless block.isValid?
                invalidBlock = self.validateTree(block, filesystemStates)
                return invalidBlock if invalidBlock != true
            end
            true
        end

        def self.validateLeafItem!(item, header, filesystemState = nil, throughout = true)

            return item.corruption.isValid? if (Constants::HEADER_SIZE + item.offset + 4) > header.block.size ||
                   item.offset < Constants::LEAF_ITEM_SIZE * header.nritems

            item.corruption.offset = false

            return item.corruption.isValid? if item.size <= 0 || item.size > MAX_DATA_SIZE ||
                   (Constants::HEADER_SIZE + item.offset + item.size) > header.block.size

            item.corruption.size = false

            validKeyTypes, isValidKey = self.getValidKeyTypes(header.owner)
            return item.corruption.isValid? if !validKeyTypes.include?(item.key.type) || !isValidKey.call(item)

            validators = {
                Constants::UNTYPED          => :validateUntyped!,
                Constants::INODE_ITEM       => :validateInodeItem!,
                Constants::INODE_REF        => :validateInodeRef!,
                Constants::XATTR_ITEM       => :validateXattrItem!,
                Constants::DIR_ITEM         => :validateDirItem!,
                Constants::DIR_INDEX        => :validateDirIndex!,
                Constants::EXTENT_DATA      => :validateExtentData!,
                Constants::EXTENT_CSUM      => :validateCsumItem!,
                Constants::ROOT_ITEM        => :validateRootItem!,
                Constants::EXTENT_ITEM      => :validateExtentItem!,
                Constants::METADATA_ITEM    => :validateExtentItem!,
                Constants::EXTENT_DATA_REF  => :validateExtentDataRef!,
                Constants::SHARED_DATA_REF  => :validateSharedDataRef!,
                Constants::BLOCK_GROUP_ITEM => :validateBlockGroupItem!,
                Constants::DEV_ITEM         => :validateDevItem!,
                Constants::CHUNK_ITEM       => :validateChunkItem!
                #Constants::VERITY_DESC_ITEM => :validateUnimplemented!
            }

            return item.corruption.isValid? unless validators.has_key?(item.key.type)

            item.corruption.setValid!
            self.send(validators[item.key.type], item, header, filesystemState, throughout)
            item.corruption.size = item.size != item.sizeRead unless item.corruption.data?

            item.corruption.isValid?
        end

        def self.validateUnimplemented!(item, header, filesystemState = nil, throughout = true)
            raise 'Not implemented!'
        end

        def self.validateUntyped!(item, header, filesystemState = nil, throughout = true)
            if item.key.objectid == Constants::FREE_SPACE_OBJECTID
                self.validateFreeSpaceHeader!(item, header, filesystemState, throughout)
            else
                item.corruption.head = true
                item.corruption.data = true
            end
        end

        def self.getValidKeyTypes(tree)
            @@KeyTypeCache ||= {}
            return @@KeyTypeCache[tree] if @@KeyTypeCache.key?(tree)
            validKeyTypes = []
            isValidKey = nil
            case tree
            when Constants::ROOT_TREE_OBJECTID
                validKeyTypes << Constants::UNTYPED
                validKeyTypes << Constants::INODE_ITEM
                validKeyTypes << Constants::INODE_REF
                validKeyTypes << Constants::DIR_ITEM
                validKeyTypes << Constants::EXTENT_DATA
                validKeyTypes << Constants::ROOT_ITEM
                isValidKey = Proc.new { |item| item.key.objectid > 0 || (item.key.type == Constants::UNTYPED && item.key.objectid == Constants::FREE_SPACE_OBJECTID) }
            when Constants::EXTENT_TREE_OBJECTID
                validKeyTypes << Constants::EXTENT_ITEM
                validKeyTypes << Constants::METADATA_ITEM
                validKeyTypes << Constants::EXTENT_DATA_REF
                validKeyTypes << Constants::SHARED_DATA_REF
                validKeyTypes << Constants::SHARED_DATA_REF
                validKeyTypes << Constants::BLOCK_GROUP_ITEM
                isValidKey = Proc.new { |item| self.isValidObjectId?(item, item.key.type != Constants::BLOCK_GROUP_ITEM) && item.key.offset >= 0 }
            when Constants::CSUM_TREE_OBJECTID
                validKeyTypes << Constants::EXTENT_CSUM
                isValidKey = Proc.new { |item| item.key.objectid == Constants::EXTENT_CSUM_OBJECTID && item.key.offset > 0 }
            when Constants::CHUNK_TREE_OBJECTID
                validKeyTypes << Constants::DEV_ITEM
                validKeyTypes << Constants::CHUNK_ITEM
                isValidKey = Proc.new { |item| self.isValidObjectId?(item) && item.key.offset > 0 }
            else
                # fs tree
                validKeyTypes << Constants::INODE_ITEM
                validKeyTypes << Constants::INODE_REF
                validKeyTypes << Constants::XATTR_ITEM
                validKeyTypes << Constants::DIR_ITEM
                validKeyTypes << Constants::DIR_INDEX
                validKeyTypes << Constants::EXTENT_DATA
                validKeyTypes << Constants::VERITY_DESC_ITEM
                isValidKey = Proc.new { |item| item.key.offset >= 0 }
            end

            @@KeyTypeCache[tree] = [validKeyTypes, isValidKey]
            @@KeyTypeCache[tree]
        end

        def self.validateNodeItem!(item, header, filesystemState = nil, throughout = true)
            return item.corruption.isValid? if item.key.nil?

            validKeyTypes, isValidKey = self.getValidKeyTypes(header.owner)

            item.corruption.key = !validKeyTypes.include?(item.key.type) || !isValidKey.call(item)

            unless item.blockNumber.nil?
                item.corruption.block = item.blockNumber <= 0 || !(item.blockNumber & (header.block.sectorsize - 1)).zero? || item.blockNumber >= MAX_BLOCK
            end

            unless item.generation.nil?
                item.corruption.generation = item.generation <= 0
            end

            item.corruption.isValid?
        end

        def self.validateNodeItems!(items, header, filesystemState = nil, throughout = true)
            allValid = true
            blocks = {}
            items.each_with_index do |item, i|
                allValid = false unless item.validate!(header, filesystemState, throughout)
                if blocks.has_key?(item.blockNumber)
                    item.corruption.block = true
                    items[blocks[item.blockNumber]].corruption.block = true
                    allValid = false
                else
                    blocks[item.blockNumber] = i
                end
            end
            allValid
        end

        def self.validateItemDuplicateOffset(item, offsets)
            if offsets.has_key?(item.offset)
                item.corruption.offset = true
                offsets[item.offset].corruption.offset = true
                return false
            else
                offsets[item.offset] = item
            end
            true
        end

        def self.validateItemDuplicateKeys(item, keys)
            keyId = [item.key.objectid, item.key.type, item.key.offset]
            if keys.has_key?(keyId)
                item.corruption.head = true
                return false
            else
                keys[keyId] = true
            end
            true
        end

        def self.validateLeafItems!(items, header, filesystemState = nil, throughout = true)
            allValid = true
            offsets = {}
            keys = {}
            maxObjectId = nil
            nodesize = filesystemState.nil? ? Constants::BLOCK_SIZE : filesystemState.superblock.nodesize
            items.each_with_index do |item, i|
                allValid = false unless item.validate!(header, filesystemState, throughout)
                next if item.corruption.offset?

                prevItem = i.zero? ? nil : items[i - 1]
                if !item.corruption.head?
                    if !maxObjectId.nil? && item.key.objectid < maxObjectId
                        item.corruption.head = true
                        allValid = false
                    elsif !prevItem.nil? && item.key.objectid == prevItem.key.objectid &&
                          (
                              item.key.type < prevItem.key.type ||
                              (item.key.type == prevItem.key.type && item.key.offset <= prevItem.key.offset)
                          )
                            item.corruption.head = true
                            allValid = false
                    end
                end
                maxObjectId = maxObjectId.nil? ? item.key.objectid : [maxObjectId, item.key.objectid].max

                if i.zero?
                    item.corruption.offset = item.offset + item.size != nodesize - Constants::HEADER_SIZE
                elsif !prevItem.corruption.offset?
                    item.corruption.offset = item.offset + item.size != prevItem.offset
                end

               allValid = self.validateItemDuplicateOffset(item, offsets) && allValid
               allValid = self.validateItemDuplicateKeys(item, keys) && allValid

                # TODO check for overlaps
            end

            allValid
        end

    end
end
