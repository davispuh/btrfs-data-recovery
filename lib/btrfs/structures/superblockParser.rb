# frozen_string_literal: true

require_relative 'superblock'
require 'ostruct'

module Btrfs
    module Structures

        def self.parseSuperblock(io)
            Superblock.new(io.read(Constants::SUPERBLOCK_SIZE).to_s)
        end

        def self.parseDevItem(data, item = nil)
            fields = %i{devid
                        totalBytes bytesUsed
                        ioAlign ioWidth
                        sectorSize
                        type generation
                        startOffset
                        devGroup
                        seekSpeed
                        bandwidth
                        uuid fsid}

            format = ""
            format += "Q<"  # devid
            format += "Q<"  # totalBytes
            format += "Q<"  # bytesUsed
            format += "L<"  # ioAlign
            format += "L<"  # ioWidth
            format += "L<"  # sectorSize
            format += "Q<"  # type
            format += "Q<"  # generation
            format += "Q<"  # startOffset
            format += "L<"  # devGroup
            format += "C"   # seekSpeed
            format += "C"   # bandwidth
            format += "a16" # uuid
            format += "a16" # fsid

            values = data.unpack(format)
            parsedData = OpenStruct.new(Hash[fields.zip(values)])
            if item
                item.data = parsedData
                item.sizeRead = 98
            end
            parsedData
        end

        def self.parseRootBackup(data)
            fields = %i{treeRoot treeRootGen
                        chunkRoot chunkRootGen
                        extentRoot extentRootGen
                        fsRoot fsRootGen
                        devRoot devRootGen
                        csumRoot csumRootGen
                        totalBytes bytesUsed
                        numDevices
                        unused64
                        treeRootLevel chunkRootLevel extentRootLevel
                        fsRootLevel devRootLevel csumRootLevel
                        unused8}

            format = ""
            format += "Q<"   # treeRoot
            format += "Q<"   # treeRootGen
            format += "Q<"   # chunkRoot
            format += "Q<"   # chunkRootGen
            format += "Q<"   # extentRoot
            format += "Q<"   # extentRootGen
            format += "Q<"   # fsRoot
            format += "Q<"   # fsRootGen
            format += "Q<"   # devRoot
            format += "Q<"   # devRootGen
            format += "Q<"   # csumRoot
            format += "Q<"   # csumRootGen

            format += "Q<"   # totalBytes
            format += "Q<"   # bytesUsed
            format += "Q<"   # numDevices
            format += "a32" # unused64

            format += "C"    # treeRootLevel
            format += "C"    # chunkRootLevel
            format += "C"    # extentRootLevel
            format += "C"    # fsRootLevel
            format += "C"    # devRootLevel
            format += "C"    # csumRootLevel
            format += "a10"  # unused8

            values = data.unpack(format)
            OpenStruct.new(Hash[fields.zip(values)])
        end

        def self.parseSuperblockData(data)

            fields = %i{csum fsid bytenr flags magic generation
                        root chunkRoot logRoot logRootTransId
                        totalBytes bytesUsed
                        rootDirObjectId numDevices
                        sectorsize nodesize
                        unusedLeafsize
                        stripesize
                        sysChunkArraySize
                        chunkRootGeneration
                        compatFlags compatRoFlags incompatFlags
                        csumType
                        rootLevel chunkRootLevel logRootLevel
                        devItem
                        label
                        cacheGeneration uuidTreeGeneration
                        metadataUUID
                        reserved
                        sysChunkArray
                        superRoots}

            format = ""
            format += "A32"   # csum
            format += "a16"   # fsid
            format += "Q<"    # bytenr
            format += "B64"   # flags

            format += "a8"   # magic
            format += "Q<"    # generation
            format += "Q<"    # root
            format += "Q<"    # chunkRoot
            format += "Q<"    # logRoot
            format += "Q<"    # logRootTransid

            format += "Q<"    # totalBytes
            format += "Q<"    # bytesUsed
            format += "Q<"    # rootDirObjectid
            format += "Q<"    # numDevices
            format += "L<"    # sectorsize
            format += "L<"    # nodesize
            format += "L<"    # unusedLeafsize
            format += "L<"    # stripesize
            format += "L<"    # sysChunkArraySize
            format += "Q<"    # chunkRootGeneration
            format += "Q<"    # compatFlags
            format += "Q<"    # compatRoFlags
            format += "Q<"    # incompatFlags
            format += "S<"    # csumType
            format += "C"     # rootLevel
            format += "C"     # chunkRootLevel
            format += "C"     # logRootLevel
            format += "a98"   # devItem
            format += "A256"  # label
            format += "Q<"    # cacheGeneration
            format += "Q<"    # uuidTreeGeneration

            format += "a16"   # metadataUuid

            format += "a224"  # reserved
            format += "a2048" # sysChunkArray
            format += "a680"  # superRoots

            values = data.unpack(format)
            superblock = OpenStruct.new(Hash[fields.zip(values)])

            superblock.devItem = self.parseDevItem(superblock.devItem)

            rootsData = superblock.superRoots
            rootSize = rootsData.length / Constants::NUM_BACKUP_ROOTS
            superblock.superRoots = []
            Constants::NUM_BACKUP_ROOTS.times do |i|
                offset = rootSize * i
                superblock.superRoots << self.parseRootBackup(rootsData[offset, rootSize])
            end

            superblock
        end

    end
end
