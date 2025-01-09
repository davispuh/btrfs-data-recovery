# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_utils'

DEBUG_LOGGER = $stdout

RSpec.describe Btrfs::Recovery do

    context "standalone" do
        ['21057101103104', '21057103855616', '21057106182144', '21057108836352'].each do |block|
            context "when using #{block} block" do
                [nil, "superblock"].each do |withSuperblock|
                    context "#{withSuperblock.nil? ? 'without' : 'with'} superblock" do
                        let(:superblock) do
                            Btrfs::Cli.parseSuperblock(TestUtils.samplesDir / 'standalone' / withSuperblock) if withSuperblock
                        end

                        it "parses blocks" do
                            blocks = []
                            expect { blocks = TestUtils.parsedBlocks(block, superblock) }.not_to raise_error
                            expect(blocks.length).to eq(2)
                        end

                        it "validates blocks" do
                            blocks = TestUtils.parsedBlocks(block, superblock)
                            states = []
                            expect { states = blocks.map { |b| b.validate! } }.not_to raise_error

                            states.each do |s|
                                expect(s).to be(true).or be(false)
                            end
                        end

                        it "converts blocks to hash" do
                            blocks = TestUtils.parsedBlocks(block, superblock)
                            blocks.map { |b| b.validate! }

                            blocks.each do |b|
                                expect(b.to_h).to be_instance_of(Hash)
                                expect(b.to_h(true)).to be_instance_of(Hash)
                            end
                        end

                        it "inspects blocks" do
                            blocks = TestUtils.parsedBlocks(block, superblock)
                            blocks.map { |b| b.validate! }

                            blocks.each do |b|
                                expect(b.inspect).to be_instance_of(String)
                            end

                            if withSuperblock
                                expect(superblock.inspect).to be_instance_of(String)
                            end
                        end

                        it "fixes block" do
                            blocks = TestUtils.parsedBlocks(block)
                            blocks.map { |b| b.validate! }

                            fixedBlock = Btrfs::Recovery.fixBlock(blocks)
                            TestUtils.getStandaloneBlockIo(block, 'fixed') do |io|
                                expect(fixedBlock[:successful]).to be(true)
                                expect(fixedBlock[:block].buffer).to eq(io.read)
                            end
                        end

                    end
                end

            end
        end
    end

    Btrfs::Cli.module_exec do
        class << self
            alias_method :getOptionsActual, :getOptions
        end

        def self.testDevices
            @testDevices
        end

        def self.testDevices=(devices)
            @testDevices = devices
        end

        def self.getOptions(...)
            options = self.getOptionsActual(...)
            options[:devices] = @testDevices if @testDevices
            options
        end
    end

    Btrfs::Recovery.module_exec do
        class << self
            alias_method :fixFilesystemsActual, :fixFilesystems
        end

        def self.testStats
            @testStats
        end

        def self.fixFilesystems(...)
            @testStats = self.fixFilesystemsActual(...)
            @testStats
        end
    end

    Btrfs::Recovery::Database.class_exec do
        alias_method :initializeActual, :initialize

        def self.testFiles=(files)
            class_variable_set(:@@testFiles, files)
        end

        def initialize(database, tracer = nil)
            initializeActual(database, tracer = nil)
            self.class.class_variable_get(:@@testFiles).to_a.each do |file|
                self.execute_batch(File.read(file))
            end
        end

        def execute_batch(sql)
            @DB.execute_batch(sql)
        end
    end

    Btrfs::Structures::FilesystemState.class_exec do
        def self.offsetsData=(data)
            @offsetsData = data
        end

        def self.getOffsetsInfo(devices, blockNumbers)
            raise 'Expected TestIO!' unless devices.all? { | device| device.is_a?(TestIO) }
            offsetsInfos = JSON.parse(@offsetsData)
            offsetsInfos.select! { |blockNumber, infos| blockNumbers.include?(blockNumber.to_i) }
            offsetsInfos.each do |blockNumber, infos|
                infos.each do |subinfos|
                    subinfos.each do |offsetInfo|
                        offsetInfo['device'] = [offsetInfo['device']].pack('H*')
                    end
                end
            end
        end
    end

    {
        '1' => { corrupted: 2, correct: 0, partial: 2, skipped: 0 },
        '2' => { corrupted: 1, correct: 1, partial: 0, skipped: 0 },
        '3' => { corrupted: 6, correct: 7, partial: 0, skipped: 0 }
    }.each do |caseId, expectedFixes|
        context "filesystem test case ##{caseId}" do
            before(:all) {
                TestUtils.initializeTestData(TestUtils.samplesDir / ('fs' + caseId))
            }

            before(:each) {
                @originalOut = $stdout
                @originalErr = $stderr
                @expectedWrites = TestUtils.loadTestData(TestUtils.samplesDir / ('fs' + caseId))
            }

            after(:each) {
                $stderr = @originalErr
                $stdout = @originalOut
            }

            it "validates repair process" do
                Dir.mktmpdir do |backupPath|
                    args = ['--database', ':memory:', '--copy', backupPath, '--quiet', 'DEVICES']
                    ARGV.clear
                    $stdout = StringIO.new
                    $stderr = StringIO.new
                    Btrfs::Cli.main(args)

                    stats = Btrfs::Recovery.testStats
                    expect(stats[:corruptedBlocks].values.flatten.length).to eq(expectedFixes[:corrupted])
                    expect(stats[:correctlyFixed]).to eq(expectedFixes[:correct])
                    expect(stats[:partiallyFixed]).to eq(expectedFixes[:partial])
                    expect(stats[:skippedBlocks].keys.length).to eq(expectedFixes[:skipped])
                    Btrfs::Cli.testDevices.map do |testDevice|
                        expect(testDevice.writtenData).to be_empty
                    end
                end
            end

            it "successfully repairs filesystem" do
                Dir.mktmpdir do |backupPath|
                    args = ['--database', ':memory:', '--copy', backupPath, '--repair', 'DEVICES']
                    ARGV.clear
                    $stdout = StringIO.new
                    $stderr = StringIO.new
                    Btrfs::Cli.main(args)

                    stats = Btrfs::Recovery.testStats
                    expect(stats[:corruptedBlocks].values.flatten.length).to eq(expectedFixes[:corrupted])
                    expect(stats[:correctlyFixed]).to eq(expectedFixes[:correct])
                    expect(stats[:partiallyFixed]).to eq(expectedFixes[:partial])
                    expect(stats[:skippedBlocks].keys.length).to eq(expectedFixes[:skipped])
                    Btrfs::Cli.testDevices.each_with_index do |testDevice, i|
                        expect(testDevice.writtenData.keys.length).to eq(@expectedWrites[i].keys.length)
                        @expectedWrites[i].each do |offset, data|
                            expect(testDevice.writtenData[offset]&.unpack('H*')&.first).to eq(@expectedWrites[i][offset]&.unpack('H*')&.first)
                        end
                    end
                end
            end

        end
    end
end
