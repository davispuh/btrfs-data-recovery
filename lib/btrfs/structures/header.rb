# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        class Header < OpenStruct

            def isNode?
                self.level > 0
            end

            def isLeaf?
                self.level&.zero?
            end

            def isValid?
                return false if self.level.nil?

                self.generation > 0 &&
                self.nritems > 0 && self.nritems < Constants::MAX_ITEMS &&
                self.level >= 0 && self.level < 10
            end

            def getChecksumType
                self.class.getChecksumType(self.csum)
            end

            def inspect
                info = "Block: #{self.bytenr}\n"
                info += "FSID: #{self.fsid.unpack('H*').first}\n"
                checksum = self.block.getChecksumType.is_a?(Integer) ? self.block.getChecksum : nil
                checksumInfo = Structures.getChecksumInfo(checksum, self.csum, self.block.getChecksumType)
                info += "Checksum: #{Structures.formatChecksum(self.csum)} (#{checksumInfo})\n"
                info += "Owner: " + Structures.formatTree(self.owner, true) + "\n" unless self.owner.nil?
                info += "Flags: #{self.flags}\n"
                info += "Generation: #{self.generation}\n"
                info += "Items: #{self.nritems}\n"
                info += "Level: #{self.level} (#{self.level.zero? ? 'LEAF' : 'NODE'})\n" unless self.level.nil?
                info
            end

            def to_h(encodeBinary = false)
                data = super()
                data.delete(:block)
                %i[fsid csum chunkTreeUUID].each do |name|
                    data[name] = '0x' + data[name].unpack('H*').first
                end
                data
            end

            def to_s
                values = [self.csum, self.fsid, self.bytenr,
                          self.flags, self.chunkTreeUUID,
                          self.generation, self.owner,
                          self.nritems, self.level]
                values.pack("A32a16Q<B64a16Q<qL<C")
            end

            def self.getChecksumType(checksum)
                if checksum.length <= 4
                    Constants::CSUM_TYPE_CRC32
                elsif checksum.length <= 8
                    Constants::CSUM_TYPE_XXHASH
                else
                    [Constants::CSUM_TYPE_SHA256, Constants::CSUM_TYPE_BLAKE2]
                end
            end

            def self.getChecksumLength(type)
                case type
                when Constants::CSUM_TYPE_CRC32
                    4
                when Constants::CSUM_TYPE_XXHASH
                    8
                when Constants::CSUM_TYPE_SHA256, Constants::CSUM_TYPE_BLAKE2
                    16
                else
                    raise "Unknown checksum (#{type})!"
                end
            end

        end

    end
end
