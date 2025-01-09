# frozen_string_literal: true

require_relative 'leafCorruption'

module Btrfs
    module Structures

        class LeafItem
            attr_reader :corruption
            attr_accessor :id, :key, :offset, :size, :sizeRead, :data

            def initialize(id)
                @id = id
                @key = nil
                @offset = nil
                @size = nil
                @sizeRead = nil
                @data = nil
                @corruption = nil
            end

            def validate!(header, filesystemState = nil, throughout = true)
                @corruption = LeafCorruption.new
                Structures.validateLeafItem!(self, header, filesystemState, throughout)
            end

            def isValid?
                return nil unless @corruption
                @corruption.isValid?
            end

            def isCorrupted?
                return nil unless @corruption
                @corruption.isCorrupted?
            end

            def to_h(encodeBinary)
                {
                    id: @id,
                    corruped: self.isCorrupted?,
                    key: @key.to_h,
                    offset: @offset,
                    size: @size,
                    sizeRead: @sizeRead,
                    data: Structures.encodeData(@data)
                }
            end

        end
    end
end
