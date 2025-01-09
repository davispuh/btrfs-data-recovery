# frozen_string_literal: true

require 'ostruct'

module Btrfs
    module Structures

        def self.formatChecksum(checksum)
            '0x' + checksum.unpack('H*').first
        end

        def self.formatTree(tree, numeric = false)
            output = ''
            if tree && tree.abs < Constants::TREE_NAMES.length
                output += Constants::TREE_NAMES[tree]
                output += " (#{tree})" if numeric
            else
                output += tree.to_s
            end
            output
        end

        def self.getChecksumInfo(checksum, expectedChecksum = nil, checksumType = nil)
            if checksumType.is_a?(Array)
                csumName = checksumType.map {|t| Constants::CSUM_NAMES[t] }.join(',')
                checksumLength = Constants::CSUM_LENGTHS[checksumType.first]
            elsif checksumType
                csumName = Constants::CSUM_NAMES[checksumType]
                checksumLength = Constants::CSUM_LENGTHS[checksumType]
            else
                csumName = 'Unknown'
                checksumLength = expectedChecksum.length if expectedChecksum
            end

            info = csumName
            if checksum && expectedChecksum
                info += ', '
                if Block.checksumMatches?(checksum, expectedChecksum)
                    info += 'VALID'
                else
                    info += 'INVALID, ' + self.formatChecksum(checksum[0, checksumLength])
                end
            end

            info
        end

        def self.encodeData(data)
            if data.is_a?(String)
                if data.encoding == Encoding::ASCII_8BIT && data.length > 0
                    original = data
                    strippedData = data.sub(/\0+$/, '')
                    zeros = original.length - strippedData.length
                    if zeros > 4
                        if strippedData.empty?
                            data = '0x00*' + zeros.to_s
                        else
                            data = '0x' + strippedData.unpack('H*').first + ' 0x00*' + zeros.to_s
                        end
                    else
                        data = '0x' + original.unpack('H*').first
                    end
                end
            else
                data = data.to_h
                data.each do |key, value|
                    if value.is_a?(Array)
                        value.each_with_index do |data2, i|
                            value[i] = self.encodeData(data2)
                        end
                    elsif value.is_a?(String)
                        data[key] = self.encodeData(value)
                    elsif value && value.respond_to?(:to_h)
                        data[key] = self.encodeData(value)
                    end
                end
            end
            data
        end

    end
end
