# frozen_string_literal: true
require 'json'

module Btrfs
    module Structures

        class FilesystemError < RuntimeError
        end

        class FilesystemState
            attr_reader :superblock

            def initialize(device)
                @devices = {}
                @offsetInfos = {}
                @dataCache = {}
                @openDevices = {}

                raise FilesystemError.new('Invalid superblock!') unless self.loadSuperblock(device)

                self.addDevice(@superblock.devItem.uuid, device)
            end

            def addDevice(deviceUUID, device)
                @devices[deviceUUID] = device
            end

            def getMissingDeviceCount()
                @superblock.numDevices - @devices.length
            end

            def usingDevice(device, write = false, &block)
                if @devices.has_key?(device)
                    device = @devices[device]
                elsif device.respond_to?(:encoding) && device.encoding.name == 'ASCII-8BIT' && device.length == Constants::UUID_SIZE
                    # Device is not present!
                    return
                end
                if write
                    if device.respond_to?(:open)
                        return device.open('rb+', &block)
                    else
                        return File.open(device, 'rb+', &block)
                    end
                elsif !@openDevices.has_key?(device)
                    @openDevices[device] = device.respond_to?(:seek) ? device : File.new(device, 'rb')
                end
                yield(@openDevices[device])
            end

            def eachOffset(blockNumbers, &block)
                blockNumbers = [blockNumbers] unless blockNumbers.is_a?(Array)
                offsetsInfo = self.getOffsetsInfo(blockNumbers)
                #if offsetsInfo.empty?
                #    puts blockNumbers
                #end
                offsetsInfo.each do |device, infos|
                    self.usingDevice(device) do |deviceIO|
                        infos.each do |info|
                            deviceIO.seek(info['physical'])
                            yield(info, self.superblock, deviceIO)
                        end
                    end
                end
            end

            def deviceUUIDs
                @devices.keys
            end

            private

            def loadSuperblock(device)
                self.usingDevice(device) do |io|
                    io.seek(Constants::SUPERBLOCK_OFFSETS.first)
                    @superblock = Structures.parseSuperblock(io)
                    if @superblock.magic != Constants::SUPERBLOCK_MAGIC
                        @superblock = nil
                    end
                end
                @superblock
            end

            def getOffsetsInfo(blockNumbers)
                offsetInfos = {}
                loadedBlockNumbers = @offsetInfos.values.reduce([]) { |o, infos|  o += infos.map { |blockNumber, info| blockNumber } }
                if !(blockNumbers - loadedBlockNumbers).empty?
                    offsetsInfos = self.class.getOffsetsInfo(@devices.values, blockNumbers)
                    offsetsInfos.each do |blockNumber, info|
                        blockNumber = blockNumber.to_i
                        info.flatten.each do |info|
                            device = info['device']
                            next if device == 'MISSING'
                            offsetInfos[device] ||= []
                            offsetInfos[device] << info
                            @offsetInfos[device] ||= {}
                            @offsetInfos[device][blockNumber] ||= []
                            @offsetInfos[device][blockNumber] << info unless @offsetInfos[device][blockNumber].include?(info)
                        end
                    end
                else
                    @offsetInfos.each do |device, infos|
                        infoList = infos.select { |blockNumber, info| blockNumbers.include?(blockNumber) }
                                           .map { |blockNumber, info| info }.flatten

                        unless infoList.empty?
                            offsetInfos[device] = infoList
                        end
                    end
                end
                offsetInfos
            end

            def self.getOffsetsInfo(devices, blockNumbers)
                blockNumbers = [blockNumbers] unless blockNumbers.is_a?(Array)
                devicesList = devices.join(',')
                blockNumberList = blockNumbers.map { |o| o.to_s }
                cmd = ['./btrfs-recovery-map', '-d', devicesList]
                blockNumbersData = ''
                if blockNumberList.length <= 10
                    cmd += blockNumberList
                else
                    blockNumbersData = blockNumberList.join("\n")
                end
                stdout, stderr, status = Open3.capture3(*cmd, stdin_data: blockNumbersData)
                if status.success?
                    stdout.strip!
                    begin
                        return JSON.parse(stdout)
                    rescue JSON::ParserError => e
                        $stderr.puts("Failed to parse offset info!\nDevices: #{devicesList}\nBlocks: #{blockNumberList.join(',')}\nJSON: #{e}\n#{stdout.empty? ? "(empty)" : stdout}\n\n")
                    end
                else
                    $stderr.puts("Failed to execute: #{cmd.join(' ')}\nExit code: #{status.exitstatus}\nError: #{stderr}\n")
                end
                {}
            end

            def dataCache(id, type)
                @dataCache[type] ||= {}
                unless @dataCache[type].has_key?(id)
                    @dataCache[type][id] = yield
                end
                @dataCache[type][id]
            end

        end
    end

end
