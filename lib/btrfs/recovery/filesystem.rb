# frozen_string_literal: true

module Btrfs
    module Recovery

        TREES = {
            :root   => Constants::ROOT_TREE_OBJECTID,
            :extent => Constants::EXTENT_TREE_OBJECTID,
            :chunk  => Constants::CHUNK_TREE_OBJECTID,
            :dev    => Constants::DEV_TREE_OBJECTID,
            :fs     => Constants::FS_TREE_OBJECTID,
            :csum   => Constants::CSUM_TREE_OBJECTID,
            :uuid   => Constants::UUID_TREE_OBJECTID
        }

        LOOKBACK_PREVIOUS_GENERATIONS = 100

        def self.deviceToString(device)
            device = device.unpack1('H*') if device.length == Constants::UUID_SIZE && !device.ascii_only?
            device
        end

        def self.log(logger, device, message, clearLine = false)
            return unless logger
            if device
                device = self.deviceToString(device)
                message = device + ': ' + message
            end
            logger.puts((clearLine ? "\eM\e[2K" : '') + message)
        end

        def self.fixFilesystems(db, tree, blockNumbers, filesystemStates, backupPath, repair = false, logger = nil)
            if TREES.has_key?(tree)
                tree = TREES[tree]
            elsif tree == :all
                tree = nil
            else
                raise "Unknown tree #{tree.upcase}"
            end

            stats = []
            stats << self.fixGenerationMismatches(db, tree, blockNumbers, filesystemStates, backupPath, repair, logger)
            stats << self.fixCorruptedBlocks(db, tree, blockNumbers, stats.last[:skippedBlocks], filesystemStates, backupPath, repair, logger)
            stats << self.fixBranches(db, tree, blockNumbers, stats.last[:skippedBlocks], filesystemStates, backupPath, repair, logger)
            self.sumStats(stats)
        end

        def self.sumStats(stats)
            first = stats.shift
            stats.reduce(first) do |result, stat|
                stat[:corruptedBlocks].each do |fsid, blockNumbers|
                    result[:corruptedBlocks][fsid] ||= []
                    result[:corruptedBlocks][fsid] += blockNumbers
                    result[:corruptedBlocks][fsid].uniq!
                end
                result[:correctlyFixed] += stat[:correctlyFixed]
                result[:partiallyFixed] += stat[:partiallyFixed]
                result[:skippedBlocks] = stat[:skippedBlocks]
                result
            end
        end

        def self.getBlockFilename(blockNumber, device, offset)
            device = device.unpack('H*').first
            "#{blockNumber}_#{device}_#{offset}.bin"
        end

        def self.fixGenerationMismatches(db, tree, blockNumbers, filesystemStates, backupPath, repair, logger)
            stats = {
                corruptedBlocks: {},
                correctlyFixed: 0,
                partiallyFixed: 0,
                skippedBlocks: {}
            }
            correctlyFixed = {}
            partiallyFixed = {}
            blockSearch = {}
            mismatches = db.generationMismatches(filesystemStates, tree, blockNumbers).group_by { |mismatch| mismatch['fsid'] }
            stats[:corruptedBlocks] = mismatches.map { |fsid, mismatches| [fsid, mismatches.map { |mismatch| mismatch['bytenr'] }.uniq] }.to_h
            mismatches.values.flatten.each do |mismatch|
                fsid = mismatch['fsid']
                deviceUuid = mismatch['deviceUuid']
                blockNumber = mismatch['bytenr']
                childGeneration = mismatch['childGeneration']
                generation = mismatch['generation']
                correctlyFixed[fsid] ||= Set.new
                partiallyFixed[fsid] ||= Set.new
                filesystemState = filesystemStates[fsid]
                mismatch['block'] = Structures.loadBlockAt(mismatch['offset'], deviceUuid, filesystemState)
                if mismatch['block'].nil?
                    self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] can't be fixed, device is missing!")
                    next
                end
                mismatch['expectedGeneration'] = [mismatch['childGeneration'], mismatch['generation']].max
                if mismatch['block'].header.bytenr == blockNumber &&
                   mismatch['block'].header.owner == mismatch['expectedOwner'] &&
                   mismatch['block'].header.generation == childGeneration &&
                   mismatch['block'].checksumMatches?
                    isCorrectlyFixed = mismatch['block'].validate!(filesystemState)
                    self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] has already been #{isCorrectlyFixed ? '' : 'partially '}fixed on disk!")
                    stats[:corruptedBlocks][fsid].delete(blockNumber)
                    next
                elsif mismatch['block'].header.owner == mismatch['expectedOwner']
                    currentGeneration = mismatch['block'].header.generation
                    if currentGeneration > childGeneration
                        parent = mismatch['parent']
                        parentBlocks = self.findParents(deviceUuid, mismatch['expectedOwner'], parent, db, filesystemState)
                        if parentBlocks.all? { |block| block.checksumMatches? && block.header.generation >= generation && block.validate!(filesystemState, false) }
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] has already been fixed on disk!")
                            stats[:corruptedBlocks][fsid].delete(blockNumber)
                        else
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Generation mismatch, parent block #{parent} wants #{childGeneration} but generation is #{currentGeneration}")
                            if stats[:corruptedBlocks][fsid].include?(parent)
                                self.log(logger, deviceUuid, "Parent block #{parent} - Corrupted so skipping this and fixing that instead!")
                            else
                                self.log(logger, deviceUuid, "Parent block #{parent} - is not included for fixing... Skipping this because parent must be fixed first!")
                            end
                        end
                        next
                    else
                        errorMessage = currentGeneration != childGeneration ? "Generation mismatch, wanted #{childGeneration} but got #{currentGeneration}" : 'Corrupted!'
                        self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - #{errorMessage}")
                    end
                else
                    mismatch['expectedGeneration'] = mismatch['childGeneration']
                    self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Missing with generation #{mismatch['expectedGeneration']}")
                    raise "Unexpected block number #{mismatch['block'].header.bytenr}" if mismatch['block'].header.bytenr != blockNumber
                end
                minGeneration = [generation, childGeneration].min
                blockCandidates = db.newestGenerations(fsid, mismatch['expectedOwner'], blockNumber, minGeneration)
                if blockCandidates.empty?
                    parents = db.newestGenerations(fsid, mismatch['expectedOwner'], mismatch['parent'])
                    if parents.length >= 2
                        blocks = parents.map { |p| Structures.loadBlockAt(p['offset'], p['deviceUuid'], filesystemState) }.compact
                        raise 'Not implemented!' if blocks.map { |b| b.getChecksum }.uniq.length != 1
                    end
                    blockSearch[fsid] ||= []
                    blockSearch[fsid] << mismatch
                else
                    goodBlock = nil
                    blockCandidates.each do |candidate|
                        candidateBlock = Structures.loadBlockAt(candidate['offset'], candidate['deviceUuid'], filesystemState)
                        if candidateBlock.nil?
                            self.log(logger, candidate['deviceUuid'], "Can't check candidate block #{candidate['bytenr']} because device is missing!")
                            next
                        end
                        if !candidateBlock.header.isValid?
                            swappedCandidateBlock = Structures.loadBlockAt(candidate['offset'], candidate['deviceUuid'], filesystemState, true)
                            candidateBlock = swappedCandidateBlock if swappedCandidateBlock.header.isValid?
                        end
                        if candidateBlock.header.bytenr == blockNumber &&
                           candidateBlock.header.generation == mismatch['expectedGeneration'] &&
                           candidateBlock.header.owner == mismatch['expectedOwner'] &&
                           (candidateBlock.header.csum != mismatch['block'].header.csum || !mismatch['block'].checksumMatches?)
                            candidateBlock.validate!(filesystemState, false)
                            goodBlock = candidateBlock
                            break
                        end
                    end
                    if goodBlock
                        targetBlockNumber = goodBlock.header.bytenr
                        targetDevice = mismatch['deviceUuid']
                        targetOffset = mismatch['offset']
                        sourceDevice = goodBlock.device
                        sourceOffset = goodBlock.deviceOffset
                        if goodBlock.checksumMatches?
                            if goodBlock.headerSwapped
                                candidateInfo = (goodBlock.isValid? ? '' : 'suspicious ') + 'copy with swapped header'
                            elsif goodBlock.isValid?
                                candidateInfo = 'good copy'
                            else
                                candidateInfo = 'potentially corrupted copy'
                            end
                            self.log(logger, targetDevice, "Block #{targetBlockNumber} - Found #{candidateInfo} with generation #{goodBlock.header.generation} at #{self.deviceToString(sourceDevice)}@#{sourceOffset}")
                            shouldCopyBlock = true
                            if !goodBlock.isValid?
                                mismatch['block'].validate!(filesystemState)
                                blocks = [mismatch['block'], goodBlock]
                                self.log(logger, fsid, "Block #{targetBlockNumber} - Trying to fix using #{blocks.length} candidate block(s)!")
                                fixedBlock = Recovery.fixBlock(blocks, filesystemState, mismatch['expectedOwner'])
                                if fixedBlock[:block] && fixedBlock[:block].isValid?
                                    self.writeFixedBlock(fixedBlock[:block], targetDevice, targetOffset, false, filesystemState, backupPath, logger, false) #repair)
                                    # We should really check if this is correct
                                    # and actually write all mirrors not just this one
                                    # otherwise mirrors will differ between each other
                                    raise 'This might not be safe!'
                                    shouldCopyBlock = false
                                else
                                    self.log(logger, targetDevice, "Block #{targetBlockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Unable to fix!")
                                end
                                partiallyFixed[fsid] << targetBlockNumber
                            end
                            if shouldCopyBlock
                                copied = self.copyBlockWithBackup(targetBlockNumber, targetDevice, targetOffset, goodBlock.header.bytenr, sourceDevice, sourceOffset, filesystemState, repair, backupPath, logger)
                                if copied.nil?
                                    self.log(logger, targetDevice, "Block #{targetBlockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Can't fix because device is missing!")
                                    stats[:skippedBlocks][targetBlockNumber] ||= []
                                    stats[:skippedBlocks][targetBlockNumber] << mismatch
                                    next false
                                end
                                self.swapHeaderLog(targetBlockNumber, targetDevice, targetOffset, filesystemState, repair, logger) if goodBlock.headerSwapped
                                self.log(logger, targetDevice, "Block #{targetBlockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Fixed! :)") if repair
                                correctlyFixed[fsid] << targetBlockNumber
                            end
                        else
                            self.log(logger, targetDevice, "Block #{targetBlockNumber} - Found corrupted #{goodBlock.headerSwapped ? 'copy with swapped header' : 'copy'} with generation #{goodBlock.header.generation} at #{self.deviceToString(sourceDevice)}@#{sourceOffset}")
                            self.log(logger, targetDevice, "Block #{targetBlockNumber} - Skipping for now, will try fixing in next pass")
                            stats[:skippedBlocks][targetBlockNumber] ||= []
                            stats[:skippedBlocks][targetBlockNumber] << mismatch
                        end
                    else
                        self.log(logger, deviceUuid, "Block #{blockNumber} - Couldn't find good alternative block, #{blockCandidates.length} candidate block(s) were rejected!")
                    end
                end
            end

            blockSearch = blockSearch.map { |fsid, mismatch| [fsid, mismatch.group_by { |m| m['expectedOwner'] }] }.to_h
            blockSearch.each do |fsid, trees|
                filesystemState = filesystemStates[fsid]
                trees.each do |expectedOwner, mismatches|
                    unreferencedBlocks = db.unreferencedBlocks(fsid, expectedOwner)
                    treeName = expectedOwner ? Constants::TREE_NAMES[expectedOwner] : ''
                    self.log(logger, fsid, "#{treeName} - Found #{unreferencedBlocks.length} unreferenced blocks")
                    mismatches.each_with_index do |mismatch, i|
                        self.log(logger, fsid, "#{treeName} [#{i + 1}/#{mismatches.length}] Block #{mismatch['bytenr']} - Searching for previous block generation...")
                        parentBlocks = self.findParents(mismatch['deviceUuid'], expectedOwner, mismatch['parent'], db, filesystemState)
                        if parentBlocks.empty?
                            self.log(logger, mismatch['deviceUuid'], "Block #{mismatch['bytenr']} - Can't fix because it's parent block #{mismatch['parent']} is invalid, skipping it!")
                            stats[:skippedBlocks][mismatch['bytenr']] ||= []
                            stats[:skippedBlocks][mismatch['bytenr']] << mismatch
                            next
                        end
                        previousBlock = self.findPreviousBlock(mismatch, parentBlocks, unreferencedBlocks, filesystemState, logger, -1)
                        if previousBlock
                            targetDevice = mismatch['deviceUuid']
                            targetBlockNumber = mismatch['bytenr']
                            sourceBlockNumber = previousBlock.header.bytenr
                            self.log(logger, targetDevice, "Block #{targetBlockNumber} - Found good replacement block #{sourceBlockNumber} with generation #{previousBlock.header.generation}")
                            if previousBlock.isNode?
                                # Validate whole tree
                                invalidBlock = Structures.validateTree(previousBlock, { fsid => filesystemState })
                                if invalidBlock != true
                                    $stderr.puts(invalidBlock.inspect)
                                    raise 'Required block is invalid!'
                                end
                            end

                            sourceDevice = previousBlock.device
                            sourceOffset = previousBlock.deviceOffset
                            targetOffset = mismatch['offset']
                            expectedGeneration = mismatch['expectedGeneration']
                            copied = self.copyBlockWithBackup(targetBlockNumber, targetDevice, targetOffset, sourceBlockNumber, sourceDevice, sourceOffset, filesystemState, repair, backupPath, logger)
                            if copied.nil?
                                self.log(logger, targetDevice, "Block #{targetBlockNumber} - Can't fix becase device is missing!")
                                next
                            end
                            if repair
                                fixedBlock = Structures.loadBlockAt(targetOffset, targetDevice, filesystemState)
                            else
                                fixedBlock = Structures.loadBlockAt(sourceOffset, sourceDevice, filesystemState)
                            end
                            fixedBlock.header.bytenr = targetBlockNumber
                            fixedBlock.header.generation = expectedGeneration
                            self.updateHeader(fixedBlock)
                            self.fixChecksum(fixedBlock)
                            partiallyFixed[fsid] << targetBlockNumber
                            if repair
                                self.writeBlock(fixedBlock, targetDevice, targetOffset, filesystemState)
                                self.log(logger, targetDevice, "Block #{targetBlockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Partially Fixed! :)")
                            else
                                newChecksum = fixedBlock.getChecksum.unpack('A*').first.unpack('H*').first
                                self.log(logger, targetDevice, "Block #{targetBlockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Would set generation to #{expectedGeneration} and update checksum to 0x#{newChecksum}")
                            end
                        else
                            self.log(logger, mismatch['deviceUuid'], "Block #{mismatch['bytenr']} - Can't fix because couldn't find previous block generation!")
                            stats[:skippedBlocks][mismatch['bytenr']] ||= []
                            stats[:skippedBlocks][mismatch['bytenr']] << mismatch
                        end
                    end
                end
            end

            stats[:correctlyFixed] = correctlyFixed.reduce(0) { |count, fsid_blocks| count += fsid_blocks.last.length }
            stats[:partiallyFixed] = partiallyFixed.reduce(0) { |count, fsid_blocks| count += fsid_blocks.last.length }
            stats
        end

        def self.findParents(deviceUuid, owner, parentBlockNumbers, db, filesystemState)
            offsets = db.offsets(deviceUuid, parentBlockNumbers)
            parentBlocks = []
            offsets.each do |offset|
                block = Structures.loadBlockAt(offset['offset'], offset['deviceUuid'], filesystemState)
                next if block.nil? || block.header.owner != owner
                parentBlocks << block
            end
            parentBlocks
        end

        def self.eachParentItem(bytenr, parentBlocks)
            parentBlocks.each do |block|
                next unless block.isNode?
                block.items.each do |item|
                    if item.blockNumber == bytenr
                        yield(block, item)
                        break
                    end
                end
            end
        end

        def self.findPreviousBlock(blockInfo, parentBlocks, unreferencedBlocks, filesystemState, logger = nil, maxDepth = -1)
            useObjectId = false
            parentItemKeys = Set.new
            parentBlockIds = Set.new
            parentBlockLevels = Set.new
            
            self.eachParentItem(blockInfo['bytenr'], parentBlocks) do |block, item|
                if [Constants::EXTENT_ITEM, Constants::METADATA_ITEM].include?(item.key.type)
                    useObjectId = true
                    parentItemKeys << item.key.objectid
                else
                    parentItemKeys << item.key.offset
                end
                parentBlockIds << block.header.bytenr
                parentBlockLevels << block.header.level
            end

            return nil if parentItemKeys.empty?

            parentCandidates = []
            parentCandidate = nil
            blockCandidate = nil

            logger.puts if logger
            unreferencedBlocks.each_with_index do |unreferencedInfo, i|
                break if maxDepth > 0 && i >= maxDepth
                self.log(logger, filesystemState.superblock.fsid, "[#{i+1}/#{unreferencedBlocks.length}] Checking unreferenced block #{unreferencedInfo['bytenr']}", true) if logger
                block = Structures.loadBlockAt(unreferencedInfo['offset'], unreferencedInfo['deviceUuid'], filesystemState)
                next if block.nil? || block.header.owner != blockInfo['expectedOwner']
                raise 'Parent is not supposed to be unreferenced!' if parentBlockIds.include?(block.header.bytenr)
                block.items.each do |item|
                    foundParentCandidate = false
                    if parentItemKeys.include?(useObjectId ? item.key.objectid : item.key.offset)
                        if block.isNode? && item.blockNumber != blockInfo['bytenr']
                            parentCandidates << [block, item]
                            foundParentCandidate = true
                            if parentCandidate.nil? && blockCandidate && item.blockNumber == blockCandidate.first.header.bytenr
                                parentCandidate = parentCandidates.last
                            end
                        end
                        if blockCandidate.nil? && parentBlockLevels.include?(block.header.level + 1)
                            blockCandidate = [block, item]
                            parentCandidate = parentCandidates.find { |parent| parent.last.blockNumber == block.header.bytenr }
                        end
                    end
                    break if foundParentCandidate || blockCandidate
                end
                break if parentCandidate && blockCandidate
            end

            if parentCandidate && blockCandidate
                if parentCandidate.last.blockNumber == blockCandidate.first.header.bytenr &&
                        parentCandidate.last.generation == blockCandidate.first.header.generation
                    if blockCandidate.first.checksumMatches? && blockCandidate.first.validate!(filesystemState, false)
                        return blockCandidate.first
                    else
                        $stderr.puts("Candidate block #{blockCandidate.first.header.bytenr} is corrupted!")
                        raise 'Not implemented'
                    end
                else
                    raise 'Not implemented!'
                end
            end
            nil
        end

        def self.copyBlockWithBackup(targetBlockNumber, targetDevice, targetOffset, sourceBlockNumber, sourceDevice, sourceOffset, filesystemState, repair, backupPath, logger)
            backupTarget = backupPath / self.getBlockFilename(targetBlockNumber, targetDevice, targetOffset)
            backupTarget = self.copyBlockToFile(targetDevice, targetOffset, filesystemState, backupTarget, true, !repair)
            copied = self.copyBlock(sourceDevice, sourceOffset, filesystemState, targetDevice, targetOffset, !repair)
            unless repair
                self.log(logger, targetDevice, "Block #{targetBlockNumber} - Would copy backup to #{backupTarget}")
                self.log(logger, targetDevice, "Block #{targetBlockNumber} - Would fix by copying #{sourceBlockNumber} from offset #{sourceOffset} to #{targetOffset}")
            end
            copied
        end

        def self.swapHeaderLog(targetBlockNumber, targetDevice, targetOffset, filesystemState, repair, logger)
            written = self.swapHeader(targetDevice, targetOffset, filesystemState, !repair)
            unless repair
                self.log(logger, targetDevice, "Block #{targetBlockNumber} - Would swap block header at #{targetOffset}")
            end
            written
        end

        def self.fixCorruptedBlocks(db, tree, blockNumbers, skippedBlocks, filesystemStates, backupPath, repair, logger)
            stats = {
                corruptedBlocks: {},
                correctlyFixed: 0,
                partiallyFixed: 0,
                skippedBlocks: skippedBlocks
            }
            invalidBlocks = db.invalidBlocks(filesystemStates, tree, blockNumbers)
            stats[:corruptedBlocks] = invalidBlocks.group_by { |blockInfo| blockInfo['fsid'] }
                                                   .map { |fsid, blockInfos|
                                                     [fsid, blockInfos.map { |blockInfo| blockInfo['bytenr'] }.uniq]
                                                   }.to_h
            invalidBlocks = invalidBlocks.group_by { |blockInfo| [blockInfo['fsid'], blockInfo['expectedOwner']] }
            invalidBlocks.each do |fsid_owner, invalidBlocks|
                fsid = fsid_owner.first
                expectedOwner = fsid_owner.last
                filesystemState = filesystemStates[fsid]

                unreferencedBlocks = db.unreferencedBlocks(fsid, expectedOwner)
                invalidBlocks.group_by { |blockInfo| blockInfo['bytenr'] }
                             .each do |blockNumber, blockInfos|
                    blocks = []
                    fixedBlocks = 0
                    minGeneration = blockInfos.map { |blockInfo| blockInfo['generation'] }.max
                    candidates = db.newestGenerations(fsid, expectedOwner, blockNumber, minGeneration - LOOKBACK_PREVIOUS_GENERATIONS)
                    if skippedBlocks[blockNumber].is_a?(Array)
                        skippedBlocks[blockNumber].each do |skippedBlock|
                            blockInfos << skippedBlock if blockInfos.none? { |blockInfo| blockInfo['deviceUuid'] == skippedBlock['deviceUuid'] &&
                                                                                         blockInfo['offset'] == skippedBlock['offset'] }
                        end
                    end

                    blockInfos.each do |blockInfo|
                        deviceUuid = blockInfo['deviceUuid']
                        offset = blockInfo['offset']
                        blockInfo['block'] = Structures.loadBlockAt(offset, deviceUuid, filesystemState)
                        blockInfo['block'].validate!(filesystemState)
                        if blockInfo['block'].nil?
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(expectedOwner)}] - Device is missing!")
                            next
                        end
                        swappedBlock = nil
                        if !blockInfo['block'].header.isValid?
                            swappedBlock = Structures.loadBlockAt(offset, deviceUuid, filesystemState, true)
                            blockInfo['block'] = swappedBlock if swappedBlock.header.isValid?
                        end
                        blockInfo['block'].validate!(filesystemState)
                        blocks << blockInfo['block']
                        candidates.delete_if { |candidate| candidate['offset'] == offset && candidate['deviceUuid'] == deviceUuid }
                        if blockInfo['block'].header.bytenr == blockNumber &&
                           blockInfo['block'].header.owner == expectedOwner &&
                           blockInfo['block'].checksumMatches? &&
                           blockInfo['block'].isValid? &&
                           (blockInfo['childGeneration'].nil? || blockInfo['childGeneration'] == blockInfo['generation']) &&
                           blockInfo['block'] != swappedBlock
                            fixedBlocks += 1
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(expectedOwner)}] has already been fixed on disk!")
                        else
                            checksumLength = Constants::CSUM_LENGTHS[blockInfo['block'].getChecksumType]
                            checksum = Structures.formatChecksum(blockInfo['block'].getChecksum[0, checksumLength])
                            expectedChecksum = Structures.formatChecksum(blockInfo['block'].header.csum[0, checksumLength])
                            checksumMessage = ", expected checksum #{expectedChecksum} but got #{checksum}"
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(expectedOwner)}] - Corrupted#{blockInfo['block'].checksumMatches? ? '!' : checksumMessage}")

                            parentBlockNumbers = db.parents(deviceUuid, blockNumber).map { |info| info['bytenr'] }
                            blockInfo['parentBlocks'] = self.findParents(deviceUuid, expectedOwner, parentBlockNumbers, db, filesystemState)
                            if !blockInfo['parentBlocks'].empty?
                                previousBlock = self.findPreviousBlock(blockInfo, blockInfo['parentBlocks'], unreferencedBlocks, filesystemState, nil, 100)
                                blocks << previousBlock if previousBlock
                            end
                        end
                    end

                    if fixedBlocks >= blocks.length
                        stats[:corruptedBlocks][fsid].delete(blockNumber)
                        next
                    end

                    candidates.each do |candidate|
                        candidateBlock = Structures.loadBlockAt(candidate['offset'], candidate['deviceUuid'], filesystemState)
                        if candidateBlock.nil?
                            self.log(logger, candidate['deviceUuid'], "Block #{candidate['bytenr']} - Device is missing!")
                            next
                        end
                        candidateBlock.validate!(filesystemState)
                        blocks << candidateBlock
                    end

                    self.log(logger, fsid, "Block #{blockNumber} - Trying to fix using #{blocks.length} candidate block(s)!")
                    fixedBlock = Recovery.fixBlock(blocks, filesystemState, expectedOwner)
                    if !fixedBlock[:successful]
                        blockInfo = blockInfos.first
                        if !blockInfo['parentBlocks'].empty?
                            self.log(logger, fsid, "Block #{blockNumber} - Couldn't fix correctly, will try again using previous generation!")
                            previousBlock = self.findPreviousBlock(blockInfo, blockInfo['parentBlocks'], unreferencedBlocks, filesystemState, logger, -1)
                            if previousBlock
                                blocks << previousBlock
                                fixedBlock = Recovery.fixBlock(blocks, filesystemState, expectedOwner)
                            end
                        end
                    end

                    if fixedBlock[:block] && fixedBlock[:block].isValid?
                        stats[fixedBlock[:successful] ? :correctlyFixed : :partiallyFixed] += 1
                        blockInfos.each do |blockInfo|
                            targetDevice = blockInfo['deviceUuid']
                            targetOffset = blockInfo['offset']
                            targetBlockNumber = blockInfo['bytenr']
                            raise 'Unexpected block number!' if targetBlockNumber != fixedBlock[:block].header.bytenr
                            self.writeFixedBlock(fixedBlock[:block], targetDevice, targetOffset, fixedBlock[:successful], filesystemState, backupPath, logger, repair)
                            stats[:skippedBlocks].delete(targetBlockNumber)
                        end
                    else
                        blockInfos.each do |blockInfo|
                            deviceUuid = blockInfo['deviceUuid']
                            blockNumber = blockInfo['bytenr']
                            self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(expectedOwner)}] - Unable to fix!")
                            stats[:skippedBlocks][blockNumber] ||= []
                            stats[:skippedBlocks][blockNumber] << blockInfo
                        end
                    end
                end
            end

            stats
        end

        def self.fixBranches(db, tree, blockNumbers, skippedBlocks, filesystemStates, backupPath, repair, logger)
            stats = {
                corruptedBlocks: {},
                correctlyFixed: 0,
                partiallyFixed: 0,
                skippedBlocks: skippedBlocks
            }
            correctlyFixed = {}
            partiallyFixed = {}
            mismatches = db.branchMismatches(filesystemStates, tree, blockNumbers)
            stats[:corruptedBlocks] = mismatches.group_by { |blockInfo| blockInfo['fsid'] }
                                                 .map { |fsid, blockInfos|
                                                     [fsid, blockInfos.map { |blockInfo| blockInfo['bytenr'] }.uniq]
                                                 }.to_h
            mismatches.each do |mismatch|
                fsid = mismatch['fsid']
                deviceUuid = mismatch['deviceUuid']
                blockNumber = mismatch['bytenr']
                generation = mismatch['childGeneration']
                correctlyFixed[fsid] ||= Set.new
                partiallyFixed[fsid] ||= Set.new
                filesystemState = filesystemStates[fsid]
                block = Structures.loadBlockAt(mismatch['blockOffset'], deviceUuid, filesystemState)
                if block.nil?
                    self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['owner'])}] can't be fixed, device is missing!")
                    next
                end
                if block.header.bytenr == blockNumber &&
                   block.header.owner == mismatch['expectedOwner'] &&
                   block.header.generation == generation &&
                   block.checksumMatches?

                    if (block.items.first.key.objectid != mismatch['objectid'] && mismatch['objectid'] != 0) ||
                       block.items.first.key.type != mismatch['type'] ||
                       block.items.first.key.offset != mismatch['offset']
                        self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] differs than expected, assuming already fixed!")
                        stats[:corruptedBlocks][fsid].delete(blockNumber)
                        next
                    end

                    blockCandidates = db.newestGenerations(fsid, mismatch['expectedOwner'], mismatch['parent'])
                    if blockCandidates.empty?
                        raise 'Parent missing! Fixing not implemented!'
                    end

                    parentBlocks = blockCandidates.map { |p| Structures.loadBlockAt(p['offset'], p['deviceUuid'], filesystemState) }.compact
                    if block.isLeaf? && parentBlocks.none? { |parentBlock| parentBlock.checksumMatches? }
                        self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(block.header.owner)}] - Parent #{parentBlocks.first.header.bytenr} is corrupted! Unable to fix!")
                        stats[:skippedBlocks][blockNumber] ||= []
                        stats[:skippedBlocks][blockNumber] << block
                        next
                    end
                    parentBlocks.select! { |parentBlock| parentBlock.checksumMatches? }
                    if parentBlocks.map { |b| b.getChecksum }.uniq.length > 1
                        raise 'Multiple potential parents! Fixing not implemented!'
                    end

                    parentBlocks.map { |b| b.validate!(filesystemState) }
                    if parentBlocks.any? { |b| !b.isValid? }
                        raise "Parent is corrupted! Fixing not implemented!"
                    end

                    seemsFine = false
                    self.eachParentItem(blockNumber, parentBlocks) do |parentBlock, item|
                        if ((item.key.objectid != mismatch['parentObjectid'] ||
                             item.key.type != mismatch['parentType'] ||
                             item.key.offset != mismatch['parentOffset']) &&
                            (block.items.first.key.objectid == item.key.objectid &&
                             block.items.first.key.type == item.key.type &&
                             block.items.first.key.offset == item.key.offset))
                            seemsFine = true
                        end
                    end
                    if seemsFine
                        # Could have been already fixed before or we found good mirror copy
                        self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] doesn't need fixing!")
                        # Don't remove because most likely it was fixed by earlier iteration
                        #stats[:corruptedBlocks][fsid].delete(blockNumber)
                        next
                    end

                    if block.isNode?
                        child = block.items.first.blockNumber
                        childGeneration = block.items.first.generation
                        childCandidates = db.newestGenerations(fsid, mismatch['expectedOwner'], child, childGeneration - 1)
                        if childCandidates.empty?
                            raise 'Child missing! Fixing not implemented!'
                        end
                        childBlocks = childCandidates.map { |p| Structures.loadBlockAt(p['offset'], p['deviceUuid'], filesystemState) }.compact
                        if childBlocks.map { |b| b.getChecksum }.uniq.length > 1
                            raise 'Multiple potential childs! Fixing not implemented!'
                        end

                        if childBlocks.map { |b| b.items.first.key }.uniq.length > 1
                            raise 'Differing child first keys! Fixing not implemented!'
                        end

                        firstKey = childBlocks.first.items.first.key
                        if block.items.first.key == firstKey
                            self.log(logger, deviceUuid, "Block #{blockNumber} - Found matching first key in child block #{childBlocks.first.header.bytenr} which means our parent is corrupted not us!")

                            self.eachParentItem(blockNumber, parentBlocks) do |block, item|
                                item.key = firstKey
                                self.updateNodeItemHead(block, item)
                                self.fixChecksum(block)
                                block.reparse!
                                block.validate!(filesystemState)
                                raise 'This shouldn\'t happen' unless block.isValid?
                                self.writeFixedBlock(block, block.device, block.deviceOffset, true, filesystemState, backupPath, logger, repair)
                                correctlyFixed[fsid] << blockNumber
                            end
                        else
                            raise 'Child first key differs from us! Fixing not implemented!'
                        end
                    else
                        raise 'This block is leaf! Fixing not implemented!'
                    end
                else
                    self.log(logger, deviceUuid, "Block #{blockNumber} [#{Structures.formatTree(mismatch['expectedOwner'])}] - Missing with generation #{mismatch['childGeneration']}")
                end
            end

            stats[:correctlyFixed] = correctlyFixed.reduce(0) { |count, fsid_blocks| count += fsid_blocks.last.length }
            stats[:partiallyFixed] = partiallyFixed.reduce(0) { |count, fsid_blocks| count += fsid_blocks.last.length }
            stats
        end

        def self.writeFixedBlock(fixedBlock, targetDevice, targetOffset, isCorrectlyFixed, filesystemState, backupPath, logger, repair = false)
            backupTarget = backupPath / self.getBlockFilename(fixedBlock.header.bytenr, targetDevice, targetOffset)
            backupTarget = self.copyBlockToFile(targetDevice, targetOffset, filesystemState, backupTarget, true, !repair)

            if repair
                self.writeBlock(fixedBlock, targetDevice, targetOffset, filesystemState)
                self.log(logger, targetDevice, "Block #{fixedBlock.header.bytenr} - #{isCorrectlyFixed ? '' : 'Partially '}Fixed! :)")
            else
                self.log(logger, targetDevice, "Block #{fixedBlock.header.bytenr} - Would copy backup to #{backupTarget}")
                newChecksum = fixedBlock.getChecksum.unpack('A*').first.unpack('H*').first
                if isCorrectlyFixed
                    self.log(logger, targetDevice, "Block #{fixedBlock.header.bytenr} - Would fix it with correct checksum 0x#{newChecksum}")
                else
                    self.log(logger, targetDevice, "Block #{fixedBlock.header.bytenr} - Would fix it partially with different checksum 0x#{newChecksum}")
                end
            end
        end

    end
end

