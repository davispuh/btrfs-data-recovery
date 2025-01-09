# frozen_string_literal: true

module Btrfs
    module IO

        def self.swapHeader(data)
            temp = data[0, 512]
            data[0, 512] = data[512, 512]
            data[512, 512] = temp
            data
        end

        def self.eachFile
            loop do
                ARGF.binmode
                io = ARGF.file
                yield(io) unless io.tty?
                ARGF.close
                break if ARGF.closed? || ARGF.file.tty? || ARGF.eof?
            end
        end
    end
end
