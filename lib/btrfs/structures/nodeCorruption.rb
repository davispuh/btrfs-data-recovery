# frozen_string_literal: true

module Btrfs
    module Structures

        class NodeCorruption
            attr_writer :key, :block, :generation

            def initialize
                self.reset!
            end

            def head?
                key? || block? || generation?
            end

            def key?
                @key
            end

            def block?
                @block
            end

            def generation?
                @generation
            end

            def isCorrupted?
                head?
            end

            def isValid?
                !self.isCorrupted?
            end

            def reset!
                @key = true
                @block = true
                @generation = true
            end

            def setValid!
                @key = false
                @block = false
                @generation = false
            end

        end

    end
end
