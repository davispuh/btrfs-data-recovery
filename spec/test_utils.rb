
require 'yaml'
require_relative 'test_io'

module TestUtils

    def self.resourcesDir
        File.expand_path('../resources', __dir__)
    end

    def self.samplesDir
        Pathname.new(File.expand_path('../samples', __dir__))
    end

    def self.getStandaloneBlockIo(block, n)
        File.open(samplesDir / "standalone/#{block}_#{n}.bin", 'rb') do |io|
            yield(io)
        end
    end

    def self.parsedBlocks(block, superblock = nil)
        blocks = []
        [0, 1].each do |n|
            getStandaloneBlockIo(block, n) do |io|
                blocks << Btrfs::Structures.parseBlock(io)
            end
        end
        blocks
    end

    def self.initializeTestData(fsDir)
        testFiles = ['config.sql',
                     'tables.sql',
                     'indexes.sql'].map do |file|
            resourcesDir + '/' + file
        end
        testFiles << (fsDir / 'db.sql').to_s
        Btrfs::Recovery::Database.testFiles = testFiles
        Btrfs::Structures::FilesystemState.offsetsData = File.read(fsDir / 'offsets.json')
    end

    def self.loadTestData(fsDir)
        devicesConfigs = YAML.load_file(fsDir / 'fs.yaml')
        Btrfs::Cli.testDevices = devicesConfigs['reads'].map do
            |deviceReads| TestIO.new(fsDir, deviceReads)
        end

        devicesConfigs['writes'].map do |deviceWrites|
            deviceWrites.to_h.map { |offset, filename|
                [offset, filename ? File.read(fsDir / filename, mode: 'rb') : nil]
            }.to_h
        end
    end

end
