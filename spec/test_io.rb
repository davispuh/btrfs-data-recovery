
class TestWriter

    def initialize(writtenData, io)
        @writtenData = writtenData
        @IO = io
        @offset = 0
    end

    def seek(offset)
        @offset = offset
    end

    def read(length, out_string = nil)
        @IO.seek(@offset)
        @IO.read(length, out_string)
    end

    def write(data)
        if @writtenData.has_key?(@offset)
            @writtenData[@offset][0, data.length] = data.dup
        else
            @writtenData[@offset] = data.dup
        end
        @offset += data.length
        data.length
    end
end

class TestIO
    attr_reader :writtenData

    def initialize(path, config)
        @path = path
        @config = config
        @writtenData = {}
        self.reload
    end

    def reload
        @offset = 0
        @localOffset = 0
        @file = nil
        @data = nil
    end

    def path
        self
    end

    def open(mode, &block)
        if mode == 'rb+'
            yield(TestWriter.new(@writtenData, self))
        else
            yield(self)
        end
        self.reload
    end

    def loadData
        @data = File.read(@path / @file, mode: 'rb') if @data.nil?
    end

    def seek(offset, whence = ::IO::SEEK_SET)
        if whence == ::IO::SEEK_END
            @offset = @config.keys.sort.last
            @file = @config[@offset]
            self.loadData
            @localOffset = @data.length + offset
        elsif whence == ::IO::SEEK_SET
            if @config.has_key?(offset)
                @offset = offset
                @file = @config[@offset]
                @localOffset = 0
                @data = nil
            else
                previousOffset = @config.keys.sort { |a, b| b <=> a }.bsearch { |x| x <= offset }
                if previousOffset.nil?
                    raise "Offset #{offset} is not configured!"
                else
                    size = File.size(@path / @config[previousOffset])
                    if offset < previousOffset + size
                        @offset = previousOffset
                        @file = @config[@offset]
                        @localOffset = offset - previousOffset
                        @data = nil
                    else
                        raise "Offset #{offset} is not configured!"
                    end
                end

            end
        else
            raise "Unsupported #{whence}"
        end
        0
    end

    def pos
        @offset + @localOffset
    end

    def read(length, out_string = nil)
        if @offset + length < Btrfs::Constants::SUPERBLOCK_OFFSETS.first
            return '\0' * length
        end
        if @file.nil?
            raise "Offset is not set!"
        end
        loadData

        if @localOffset + length > @data.length
            raise 'Out of bounds read!'
        end
        data = @data[@localOffset, length]
        if @writtenData.has_key?(@offset) && @localOffset < @writtenData[@offset].length
            writtenData = @writtenData[@offset][@localOffset, length]
            if writtenData.length < length
                data = writtenData + data[writtenData.length..length]
            else
                data = writtenData
            end
            File.write("/tmp/block_#{@offset}_new.bin", data)
        end
        @localOffset += length
        if out_string
            out_string.replace(data)
            out_string
        else
            data
        end
    end

end
