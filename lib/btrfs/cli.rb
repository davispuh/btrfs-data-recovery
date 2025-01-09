# frozen_string_literal: true

require_relative 'btrfs'
require 'optparse'
require 'json'
require 'set'
require 'pathname'

module Btrfs
    module Cli

        def self.getOptions(args)
            options = { database: nil, backupPath: './backup', devices: [], superblock: nil, blocks: [], tree: :all, outputFilename: nil, repair: false, print: false, quiet: false, swapHeader: false }
            parser = OptionParser.new do |opts|
                opts.banner = "Usage: #{$0} [options] <devices...>"

                opts.on('-d','--database DB', 'Path to database for automatic repair') do |database|
                    options[:database] = database
                end
                opts.on('-t','--tree TREE', [:all, :root, :extent, :chunk, :dev, :fs, :csum, :uuid], 'Limit repair to specified tree (root, extent, chunk, dev, fs, csum, uuid)') do |tree|
                    options[:tree] = tree
                end
                opts.on('-c','--copy PATH', 'Path where to copy block backup (default: ./backup/)') do |backupPath|
                    options[:backupPath] = backupPath
                end
                opts.on('-s','--superblock FILE', 'Path to superblock') do |superblock|
                    options[:superblock] = superblock
                end
                opts.on('-b','--blocks IDs', Array, 'Block numbers') do |blocks|
                    options[:blocks] = blocks
                end
                opts.on('-o','--output FILE', 'File where to write fixed block') do |file|
                    options[:outputFilename] = file
                end
                opts.on('--[no-]repair', TrueClass, 'Repair') do |r|
                    options[:repair] = r
                end
                opts.on('-p', '--[no-]print', TrueClass, 'Print full info') do |p|
                    options[:print] = p
                end
                opts.on('-q', '--[no-]quiet', TrueClass, 'Don\'t output info') do |q|
                    options[:quiet] = q
                end
                opts.on('-x', TrueClass, 'Swap first 1024 bytes') do |x|
                    options[:swapHeader] = x
                end
                opts.on_tail('-h', '--help', 'Show this message') do
                    $stderr.puts opts
                    return false
                end
            end
            begin
                options[:devices] = parser.parse!(args).uniq
            rescue OptionParser::ParseError => e
                $stderr.puts e.message
                return false
            end
            return options
        end

        def self.parseBlocks(blockNumbers = [], filesystemStates = nil, superblock = nil, swapHeader = false)
            blocks = []
            blockNumbers.map! { |blockNumber| blockNumber.to_i }
            if blockNumbers.any? { |blockNumber| blockNumber <= 0 }
                $stderr.puts 'Block must be a number larger than 0'
                blockNumbers.keep_if { |blockNumber| blockNumber > 0 }
            end

            blocks += Structures.loadBlocksByIDs(blockNumbers, filesystemStates, superblock, swapHeader)
            notFound = blockNumbers - blocks.map { |block| block.header.bytenr }
            $stderr.puts "Failed to find blocks: #{notFound.join(',')}" unless notFound.empty?

            IO.eachFile do |io|
                block = Structures.loadBlock(io, superblock, filesystemStates, swapHeader)
                blocks << block
            end

            blocks
        end

        def self.parseSuperblock(file)
            return nil unless file

            superblock = nil
            reader = lambda do |io|
                superblock = Structures.parseSuperblock(io)
                if superblock.magic != Constants::SUPERBLOCK_MAGIC
                    io.seek(Constants::SUPERBLOCK_OFFSETS.first)
                    superblock = Structures.parseSuperblock(io)
                    superblock = nil if superblock.magic != Constants::SUPERBLOCK_MAGIC
                end
            end
            file.respond_to?(:open) ? file.open('rb', &reader) : File.open(file, 'rb', &reader)
            superblock
        end

        def self.showSuperInfo(superblock, fullInfo = false)
            if superblock
                puts superblock.inspect
                puts JSON.pretty_generate(superblock.to_h(true)) if fullInfo
                puts
            end
        end

        def self.showBlocksInfo(blocks, fullInfo = false)
            blocks.each do |block|
                puts block.inspect
                puts JSON.pretty_generate(block.to_h(true)) if fullInfo
                puts
            end
        end

        def self.showDeviceError(device, message)
            $stderr.puts(device + ': ' + message)
        end

        def self.createFilesystemStates(devices, args)
            states = {}
            devices.each do |device|
                tooSmall = false
                reader = lambda do |io|
                    io.seek(0, ::IO::SEEK_END)
                    tooSmall = io.pos < Constants::SUPERBLOCK_OFFSETS.first + Constants::SUPERBLOCK_SIZE
                end
                device.respond_to?(:open) ? device.open('rb', &reader) : File.open(device, 'rb', &reader)
                next if tooSmall
                begin
                    fs = Structures::FilesystemState.new(device)
                rescue Structures::FilesystemError => e
                    self.showDeviceError(device, e.message)
                    next
                end

                if !fs.superblock.isValid?
                    self.showDeviceError(device, 'Invalid superblock!')
                    next
                end

                args.delete(device)

                fsid = fs.superblock.devItem.fsid
                if states.has_key?(fsid)
                    states[fsid].addDevice(fs.superblock.devItem.uuid, device)
                    next
                end

                states[fsid] = fs
            end
            states
        end

        def self.warnMissingDevices(filesystemStates)
            filesystemStates.each do |fsid, state|
                missing = state.getMissingDeviceCount()
                if !missing.zero?
                    self.showDeviceError(fsid.unpack1('H*'), "WARNING! #{missing} device(s) are missing!")
                end
            end
        end

        def self.extendFilesystemState(filesystemStates, db)
            Structures::FilesystemState.define_method(:isTreePresent?) do |tree|
                db.isTreePresent?(self.deviceUUIDs, tree)
            end
            anyKeyData = filesystemStates.any? { |fsid, state| db.anyKeyData?(state.deviceUUIDs) }
            if anyKeyData
                Structures::FilesystemState.define_method(:findItems) do |type, objectid,  offset|
                    db.findKeyData(self.deviceUUIDs, { type: type, objectid: objectid,  offset: offset })
                end
                Structures::FilesystemState.define_method(:findExtentBackref) do |bytenr|
                    db.findKeyData(self.deviceUUIDs, { type: Constants::EXTENT_DATA, data: bytenr })
                end
            end
        end

        def self.main(args)
            options = getOptions(args)
            return false unless options

            superblockOverride = nil
            superblockFiles = options[:devices].dup
            superblockFiles << options[:superblock] if options[:superblock]
            superblockFiles.uniq!
            superblockFiles.each do |file|
                superblock = self.parseSuperblock(file)
                superblockOverride = superblock if file == options[:superblock]
                self.showSuperInfo(superblock, options[:print]) unless options[:quiet]
            end

            filesystemStates = self.createFilesystemStates(options[:devices], args)
            if filesystemStates.empty? && (!options[:blocks].empty? || options[:database])
                $stderr.puts('You must specify devices when using block number or database option!')
                return -1
            end

            self.warnMissingDevices(filesystemStates)

            if options[:database]
                db = Recovery::Database.new(options[:database])
                self.extendFilesystemState(filesystemStates, db)
            end
            blocks = self.parseBlocks(options[:blocks], filesystemStates, superblockOverride, options[:swapHeader])
            if blocks.empty? && !options[:database]
                $stderr.puts('You must specifiy atleast one block!')
                return -1
            end
            self.showBlocksInfo(blocks, options[:print]) unless options[:quiet]

            if options[:database]
                stats = Recovery.fixFilesystems(db, options[:tree], options[:blocks], filesystemStates, Pathname.new(options[:backupPath]), options[:repair], options[:quiet] ? nil : $stderr)
                corruptedBlocks = stats[:corruptedBlocks].reduce(0) { |count, fsid_blocks| count += fsid_blocks.last.length }
                if corruptedBlocks.zero?
                    $stderr.puts('Didn\'t find any issues!')
                else
                    shortInfo = stats[:correctlyFixed].to_s + '+' + stats[:partiallyFixed].to_s + '/' + corruptedBlocks.to_s
                    nonRepair = 'Would have correctly'
                    message = (options[:repair] ? 'Correctly' : nonRepair) + " fixed #{stats[:correctlyFixed]} block(s) and " +
                              "partially fixed #{stats[:partiallyFixed]} block(s) out of " +
                              "total #{corruptedBlocks} corrupted block(s)!"
                    $stderr.puts("[#{shortInfo}] #{message}")
                end
            end

            if options[:outputFilename]
                if blocks.empty?
                    $stderr.puts('No blocks to write!')
                    return 0
                end
                fixedBlock = Recovery.fixBlock(blocks, filesystemStates.values.first)
                if fixedBlock[:block].nil?
                    $stderr.puts('Unable to fix anything')
                    return -4
                end
                File.write(options[:outputFilename], fixedBlock[:block].buffer)
                if fixedBlock[:successful]
                    $stderr.puts('Successfully fixed block!')
                elsif fixedBlock[:block].isValid?
                    if blocks.length == 1 && blocks.first.header.csum == fixedBlock[:block].header.csum
                        $stderr.puts('Wrote block file as it was!')
                    else
                        $stderr.puts('Partially fixed!')
                        $stderr.puts("New checksum #{Structures.formatChecksum(fixedBlock[:block].header.csum)}")
                        return -3
                    end
                else
                    $stderr.puts('Failed to fix block!')
                    return -3
                end
            end

            return 0
        rescue Interrupt => i
            $stderr.puts("Interrupt! Aborted!")
            return -2
        rescue SystemCallError => e
            $stderr.puts e
            return -e.errno
        end
    end
end
