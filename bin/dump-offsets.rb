#!/usr/bin/env ruby

require 'json'
require 'yaml'

BLOCK_SIZE = 16384

def main
    if ARGV.length < 1
        puts "Usage: #{$0} <offsets.json>"
        exit -1
    end

    offsetsFile = ARGV.shift
    processOffsets(offsetsFile)
end

def processOffsets(offsetsFile)
    fs = { 'reads' => [] }
    allUuids = []
    data = JSON.load_file(offsetsFile)
    data.each do |block, mirrors|
        offsets = []
        devices = []
        uuids = []
        mirrors.each do |parts|
            raise 'Not Implemented!' if parts.length != 1
            offset = parts[0]['physical']
            uuid = parts[0]['deviceUUID']
            offsets << offset
            devices << parts[0]['device']
            uuids << uuid
            i = allUuids.index(uuid)
            if i.nil?
                allUuids << uuid
                i = allUuids.length - 1
            end
            fs['reads'][i] ||= {}
            fs['reads'][i][offset] = nil
        end
        if offsets.uniq.length == 1
            filenames = dumpBlocks(block, offsets.first, devices)
            filenames.each_with_index do |filename, i|
                j = allUuids.index(uuids[i])
                fs['reads'][j][offsets.first] = filename
            end
        else
            offsets.each_with_index do |offset, i|
                filenames = dumpBlocks(block, offset, [devices[i]])
                raise 'Unexpected' if filenames.length != 1
                j = allUuids.index(uuids[i])
                fs['reads'][j][offset] = filenames.first
            end
        end
    end
    fs['reads'].each_with_index do |reads, i|
        fs['reads'][i] = reads.sort.to_h
    end
    puts YAML.dump(fs)
end

def createFilename(block, offset, i)
    filename = block.to_s + '_' + offset.to_s
    filename += '_' + i.to_s unless i.nil?
    filename += '.bin'
    filename
end

def dumpBlocks(block, offset, devices)
    datas = []
    devices.each do |device|
        file = File.new(device, 'rb')
        file.seek(offset)
        datas << file.read(BLOCK_SIZE)
    end
    filenames = []
    if datas.uniq.length == 1
        filename = createFilename(block, offset, nil)
        datas.length.times do
            filenames << filename
        end
        File.write(filename, datas.first)
    else
        datas.each_with_index do |data, i|
            filename = createFilename(block, offset, i)
            filenames << filename
            File.write(filename, data)
        end
    end
    filenames
end

main
