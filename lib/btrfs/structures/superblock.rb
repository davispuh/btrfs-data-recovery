# frozen_string_literal: true

module Btrfs
    module Structures

        class Superblock
            attr_reader :buffer, :data

            def initialize(buffer)
                @buffer = buffer
            end

            def data
                @data ||= Structures.parseSuperblockData(@buffer)
                @data
            end

            def getChecksum
                Block.calculateChecksum(@buffer[0x20..-1], data.csumType)
            end

            def isValid?
                return false if self.data.magic != Constants::SUPERBLOCK_MAGIC

                Block.checksumMatches?(self.getChecksum, self.csum)
            end

            def method_missing(method, *args, &block)
                if data.respond_to?(method)
                    data.public_send(method, *args, &block)
                else
                    super
                end
            end

            def respond_to_missing?(method, include_private = false)
                data.respond_to?(name) || super
            end


            def to_h(encodeBinary)
                Structures.encodeData(data)
            end

            def inspect
                info = "Superblock: #{self.bytenr}\n"
                info += "FSID: #{self.fsid.unpack('H*').first}\n"
                checksumInfo = Structures.getChecksumInfo(self.getChecksum, self.csum, self.csumType)
                info += "Checksum: #{Structures.formatChecksum(self.csum)} (#{checksumInfo})\n"
                info += "Magic: #{self.magic}\n"
                info += "Label: #{self.label}\n"
                info += "Flags: #{self.flags}\n"
                info += "Generation: #{self.generation}\n"
                info += "Root: #{self.root}\n"
                info += "ChunkRoot: #{self.chunkRoot}\n"
                info += "Root: #{self.chunkRoot}\n"
                info += "Devices: #{self.numDevices}\n"
                info += "Sectorsize: #{self.sectorsize}\n"
                info += "Nodesize: #{self.nodesize}\n"

                info += "DEV UUID: #{self.devItem.uuid.unpack('H*').first}\n"
                info += "DEV FSID: #{self.devItem.fsid.unpack('H*').first}\n"

                info
            end

        end
    end
end
