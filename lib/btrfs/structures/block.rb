# frozen_string_literal: true

require_relative 'blockValidator'
require 'stringio'
require 'digest'
require 'digest/crc32c'
require 'xxhash'

module Btrfs
    module Structures

        class Block
            attr_reader :buffer, :superblock
            attr_accessor :device, :deviceOffset, :headerSwapped

            def initialize(buffer, superblock = nil)
                raise 'Invalid buffer!' if buffer.nil?
                @buffer = buffer
                @superblock = superblock
                @header = nil
                @items = nil
                @isValidated = false
            end

            def header(reparse = false)
                @header = nil if reparse
                @header ||= Structures.parseHeader(@buffer, self)
                @header
            end

            def items(reparse = false)
                @items = nil if reparse
                @items ||= Structures.parseItems(self.itemCount, @buffer, self.getType)
                @items
            end

            def reparse!
                self.header(true)
                self.items(true)
                true
            end

            def stream
                @stream ||= StringIO.new(@buffer)
                @stream
            end

            def isLeaf?
                header.isLeaf?
            end

            def isNode?
                header.isNode?
            end

            def getType
                self.isLeaf? ? :leaf : :node
            end

            def itemCount
                [self.header.nritems.to_i, Constants::MAX_ITEMS].min
            end

            def size
                return superblock.nodesize if superblock

                Constants::BLOCK_SIZE
            end

            def sectorsize
                return superblock.sectorsize if superblock

                Constants::SECTOR_SIZE
            end

            def getChecksumType
                return self.superblock.csumType if self.superblock

                self.header.getChecksumType
            end

            def inspect
                data = header.inspect
                self.items.each do |item|
                    if item.isCorrupted?
                        data += "\n"
                        if self.isLeaf?
                            data += "Corrupted item #{item.corruption.to_s} for ##{item.id}: #{item.offset}, type #{item.key.type}"
                        else
                            data += "Corrupted item for ##{item.id}: type: #{item.key&.type}, block #{item.blockNumber}, gen #{item.generation}"
                        end
                    end
                end
                data
            end

            def getChecksum
                self.class.calculateChecksum(@buffer[0x20..-1], self.getChecksumType)
            end

            def checksumMatches?
                self.class.checksumMatches?(self.getChecksum, self.header.csum)
            end

            def isValid?
                return nil unless @isValidated
                @isValid
            end

            def validate!(filesystemState = nil, throughout = true)
                if self.isLeaf?
                    @isValid = Structures.validateLeafItems!(self.items, self.header, filesystemState, throughout)
                else
                    @isValid = Structures.validateNodeItems!(self.items, self.header, filesystemState, throughout)
                end
                @isValidated = true
                @isValid
            end

            def getCorruptedItems
                raise 'Block is not validated!' unless @isValidated
                self.items.select do |item|
                    item.isCorrupted?
                end
            end

            def to_h(encodeBinary = false)
                {
                    header: self.header.to_h(encodeBinary),
                    items: self.items.map { |i| i.to_h(encodeBinary) }
                }
            end

            def dup
                self.class.new(@buffer.dup, @superblock)
            end

            def self.calculateChecksum(data, type)
                return nil if data.nil?

                case type
                when Constants::CSUM_TYPE_CRC32
                    [Digest::CRC32c.checksum(data), 0, 0, 0, 0].pack("L<L<Q<Q<Q<")
                when Constants::CSUM_TYPE_XXHASH
                    [XXhash.xxh64(data), 0, 0, 0].pack("Q<Q<Q<Q<")
                when Constants::CSUM_TYPE_SHA256
                    Digest::SHA256.digest(data)
                when Constants::CSUM_TYPE_BLAKE2
                    [0, 0, 0, 0].pack("Q<Q<Q<Q<")
                else
                    raise "Unknown checksum (#{type})!"
                end
            end

            def self.checksumMatches?(checksum, expectedChecksum)
                return false unless checksum && expectedChecksum
                length = expectedChecksum.length
                checksum[0, length] == expectedChecksum
            end

        end
    end
end
