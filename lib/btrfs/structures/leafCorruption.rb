# frozen_string_literal: true

module Btrfs
    module Structures

        class LeafCorruption
            attr_writer :head, :offset, :size, :data

            def initialize
                self.reset!
            end

            def head?
                @head || offset? || size?
            end

            def offset?
                @offset
            end

            def size?
                @size
            end

            def data?
                @data
            end

            def isCorrupted?
                head? || data?
            end

            def isValid?
                !self.isCorrupted?
            end

            def reset!
                @head = true
                @offset = true
                @size = true
                @data = true
            end

            def setValid!
                @head = false
                @offset = false
                @size = false
                @data = false
            end

            def to_s
                return 'offset' if offset?
                return 'head' if head?
                return 'data' if data?
                'none'
            end
        end

    end
end
