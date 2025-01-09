# frozen_string_literal: true

require 'sqlite3'

module Btrfs
    module Recovery
        class Database
            attr_accessor :trace

            def initialize(database, tracer = nil)
                @DB = SQLite3::Database.open(database)
                if tracer
                    @DB.trace { |cmd| tracer.puts(cmd) }
                end
                @DB.results_as_hash = true
                @DB.temp_store = :memory
                @DB.cache_size = -0x80000
                @DB.mmap_size = 0x20000000
            end

            def generationMismatches(filesystemStates, owner = nil, blockNumbers = [])
                deviceUuids = filesystemStates.reduce([]) do |uuids, state|
                    uuids += state.last.deviceUUIDs
                end
                params = deviceUuids.dup
                criteria = []
                if owner
                    params << owner
                    criteria << 'refs.owner = ?'
                end
                if !blockNumbers.empty?
                    params += blockNumbers
                    criteria << 'blocks.bytenr IN (' + self.placeholders(blockNumbers.length) + ')'
                end
                query = %Q{
                    SELECT blocks.fsid, blocks.deviceUuid, blocks.offset, blocks.owner, refs.owner AS expectedOwner, blocks.level,
                           blocks.bytenr, refs.bytenr AS parent,
                           blocks.generation, refs.childGeneration
                    FROM blocks
                    JOIN refs ON refs.deviceUuid = blocks.deviceUuid AND refs.child = blocks.bytenr
                    LEFT JOIN blocks parent ON parent.deviceUuid = refs.deviceUuid AND parent.bytenr = refs.bytenr
                    WHERE blocks.deviceUuid IN (#{self.placeholders(deviceUuids.length)}) AND
                          blocks.generation <> refs.childGeneration
                          #{criteria.empty? ? '' : ' AND (' + criteria.join(' OR ') + ')'}
                    ORDER BY blocks.level, refs.childGeneration DESC
                }
                @DB.execute(query, params)
            end

            def invalidBlocks(filesystemStates, owner = nil, blockNumbers = [])
                deviceUuids = filesystemStates.reduce([]) do |uuids, state|
                    uuids += state.last.deviceUUIDs
                end
                params = deviceUuids.dup
                criteria = []
                if owner
                    params << owner
                    criteria << 'refs.owner = ?'
                end
                if !blockNumbers.empty?
                    params += blockNumbers
                    criteria << 'blocks.bytenr IN (' + self.placeholders(blockNumbers.length) + ')'
                end
                query = %Q{
                    SELECT DISTINCT blocks.fsid, blocks.deviceUuid, blocks.offset, blocks.owner, refs.owner AS expectedOwner, blocks.level, blocks.bytenr, blocks.generation
                    FROM blocks
                    JOIN refs ON refs.deviceUuid = blocks.deviceUuid AND refs.child = blocks.bytenr
                    WHERE blocks.deviceUuid IN (#{self.placeholders(deviceUuids.length)}) AND isValid = 0
                          #{criteria.empty? ? '' : ' AND (' + criteria.join(' OR ') + ')'}
                }
                @DB.execute(query, params)
            end

            def branchMismatches(filesystemStates, owner = nil, blockNumbers = [])
                deviceUuids = filesystemStates.reduce([]) do |uuids, state|
                    uuids += state.last.deviceUUIDs
                end
                params = deviceUuids.dup
                criteria = []
                if owner
                    params << owner
                    criteria << 'blocks.owner = ?'
                end
                if !blockNumbers.empty?
                    params += blockNumbers
                    criteria << 'blocks.bytenr IN (' + self.placeholders(blockNumbers.length) + ')'
                end
                query = %Q{
                    SELECT corruptBranches.deviceUuid, corruptBranches.bytenr, corruptBranches.child,
                           corruptBranches.objectid, corruptBranches.type, corruptBranches.offset,
                           blocks.fsid, blocks.offset AS blockOffset, blocks.owner, blocks.level, blocks.generation,
                           refs.bytenr AS parent, refs.owner AS expectedOwner, refs.childGeneration,
                           refs.objectid AS parentObjectid, refs.type AS parentType, refs.offset AS parentOffset
                    FROM corruptBranches
                    LEFT JOIN blocks ON blocks.deviceUuid = corruptBranches.deviceUuid AND blocks.bytenr = corruptBranches.bytenr
                    LEFT JOIN refs ON refs.deviceUuid = corruptBranches.deviceUuid AND refs.child = corruptBranches.bytenr
                    WHERE corruptBranches.deviceUuid IN (#{self.placeholders(deviceUuids.length)})
                          #{criteria.empty? ? '' : ' AND (' + criteria.join(' OR ') + ')'}
                }
                @DB.execute(query, params)
            end

            def offsets(deviceUuid, blockNumbers)
                blockNumbers = [blockNumbers] unless blockNumbers.is_a?(Array)
                params = [deviceUuid]
                params += blockNumbers
                query = %Q{
                    SELECT deviceUuid, offset, bytenr, generation
                    FROM blocks
                    WHERE deviceUuid = ? AND bytenr IN (#{self.placeholders(blockNumbers.length)})
                    ORDER BY generation DESC, offset, deviceUuid
                }
                @DB.execute(query, params)
            end

            def parents(deviceUuid, blockNumbers)
                blockNumbers = [blockNumbers] unless blockNumbers.is_a?(Array)
                params = [deviceUuid]
                params += blockNumbers
                query = %Q{
                    SELECT deviceUuid, bytenr, child, childGeneration
                    FROM refs
                    WHERE deviceUuid = ? AND child IN (#{self.placeholders(blockNumbers.length)})
                    ORDER BY childGeneration DESC, bytenr, deviceUuid
                }
                @DB.execute(query, params)
            end

            def newestGenerations(fsid, owner, bytenr, minGeneration = 0)
                query = %Q{
                    SELECT deviceUuid, offset, bytenr, owner, level, generation, isValid
                    FROM blocks
                    WHERE fsid = :fsid AND owner = :owner AND bytenr = :bytenr AND generation > :generation
                    ORDER BY generation DESC
                }
                @DB.execute(query, { fsid: fsid, owner: owner, bytenr: bytenr, generation: minGeneration }).dup
            end

            def unreferencedBlocks(fsid, owner)
                query = %Q{
                    SELECT blocks.deviceUuid, blocks.offset, blocks.owner, level, blocks.bytenr, generation
                    FROM blocks
                    LEFT JOIN refs childs ON blocks.deviceUuid = childs.deviceUuid AND childs.child = blocks.bytenr
                    LEFT JOIN refs parents ON blocks.deviceUuid = parents.deviceUuid AND blocks.bytenr = parents.bytenr
                    WHERE fsid = :fsid AND blocks.owner = :owner AND childs.bytenr IS NULL AND parents.bytenr IS NULL
                    GROUP BY blocks.bytenr, generation, blocks.owner, level, csum
                    ORDER BY generation DESC, blocks.bytenr
                }
                @DB.execute(query, { fsid: fsid, owner: owner })
            end

            def anyKeyData?(deviceUuids)
                params = deviceUuids.dup
                query = %Q{
                    SELECT keys.deviceUuid
                    FROM keys
                    WHERE keys.deviceUuid IN (#{self.placeholders(deviceUuids.length)})
                    LIMIT 1
                }
                !@DB.execute(query, params).empty?
            end

            def findKeyData(deviceUuids, filter)
                params = deviceUuids.dup
                params += filter.values
                fields = filter.keys.map { |name| "keys.#{name} = ?"}.join(' AND ')
                query = %Q{
                    SELECT DISTINCT keys.bytenr, keys.objectid, keys.type, keys.offset, keys.data, blocks.owner
                    FROM keys
                    LEFT JOIN blocks INDEXED BY BlocksGeneration ON blocks.deviceUuid = keys.deviceUuid AND blocks.bytenr = keys.bytenr
                    WHERE keys.deviceUuid IN (#{self.placeholders(deviceUuids.length)}) AND
                          #{fields}
                }
                @DB.execute(query, params)
            end

            def isTreePresent?(deviceUuids, tree)
                params = [tree]
                params += deviceUuids.dup
                query = %Q{
                    SELECT 1
                    FROM refs
                    WHERE owner = ? AND deviceUuid IN (#{self.placeholders(deviceUuids.length)})
                    LIMIT 1
                }
                !@DB.get_first_value(query, params).nil?
            end

            private

            def placeholders(count)
                Array.new(count, '?').join(', ')
            end

        end
    end
end
