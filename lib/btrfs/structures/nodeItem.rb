# frozen_string_literal: true

require_relative 'nodeCorruption'

module Btrfs
    module Structures

        class NodeItem
            attr_reader :id, :corruption
            attr_accessor :key, :blockNumber, :generation

            def initialize(id)
                @id = id
                @key = nil
                @blockNumber = nil
                @generation = nil
                @corruption = nil
            end

            def validate!(header, filesystemState = nil, throughout = true)
                @corruption = NodeCorruption.new
                Structures.validateNodeItem!(self, header, filesystemState, throughout)
            end

            def isValid?
                return nil unless @corruption
                @corruption.isValid?
            end

            def isCorrupted?
                return nil unless @corruption
                @corruption.isCorrupted?
            end
            
            def equal?(otherItem)
                id == otherItem.id &&
                key == otherItem.key &&
                blockNumber == otherItem.blockNumber &&
                generation == otherItem.generation
            end

            def to_h(encodeBinary)
                {
                    id: @id,
                    corruped: self.isCorrupted?,
                    key: @key.to_h,
                    blockNumber: @blockNumber,
                    generation: @generation
                }
            end

        end
    end
end
