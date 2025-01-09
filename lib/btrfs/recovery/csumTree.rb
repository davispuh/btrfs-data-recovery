# frozen_string_literal: true

require 'open3'

module Btrfs
    module Recovery

        def self.fixCsumData(corruptedBlock, filesystemState = nil)
            return unless filesystemState

            allChecksums = filesystemState.getBlockChecksums(corruptedBlock)
            return if allChecksums.empty?

            corruptedBlock.items.each_with_index do |item|
                next if item.isValid? || item.corruption.head? || item.data.nil?
                item.data.csums.each_with_index do |csum, csumId|
                    actualChecksums = allChecksums[item.id][csumId]
                    if actualChecksums.length == 1
                        if csum != actualChecksums.first
                            item.corruption.data = false
                            item.data.csums[csumId] = actualChecksums.first
                            offset = Constants::HEADER_SIZE + item.offset + csumId * csum.length
                            corruptedBlock.buffer[offset, csum.length] = actualChecksums.first
                        end
                    else
                        raise 'Not implemented! Copies differ!'
                    end
                end
            end
        end

    end
end
