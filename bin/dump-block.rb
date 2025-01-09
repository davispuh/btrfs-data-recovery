#!/usr/bin/env ruby

BLOCK_SIZE = 16384

def main
    if ARGV.length < 2
        puts "Usage: #{$0} <block_nr> <offset> <devices..>"
        exit -1
    end

    block = Integer(ARGV.shift) rescue nil
    raise 'Block must be a number!' if block.nil?
    offset = Integer(ARGV.shift) rescue nil
    raise 'Offset must be a number!' if offset.nil?
    devices = ARGV
    dumpBlocks(block, offset, devices)
end

def dumpBlocks(block, offset, devices)
    puts "Dumping block #{block}"
    devices.each_with_index do |device, i|
        outputFilename = block.to_s + '_' + offset.to_s + '_' + i.to_s + '.bin'
        file = File.new(device, 'rb')
        file.seek(offset)
        data = file.read(BLOCK_SIZE)
        File.write(outputFilename, data)
    end
end

main
