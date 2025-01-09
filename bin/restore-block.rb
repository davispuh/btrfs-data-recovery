#!/usr/bin/env ruby

def main
    if ARGV.length < 3
        puts "Usage: #{$0} <offset> <file> <device>"
        exit -1
    end

    offset = ARGV.shift.to_i
    file = ARGV.shift
    device = ARGV.shift
    restoreBlock(offset, file, device)
end

def restoreBlock(offset, file, device)
    puts "Block at #{offset}"
    cmd = "dd seek=#{offset / 4096} bs=4096 conv=notrunc if=#{file} of=#{device}"
    puts cmd
    # Risky
    #`#{cmd}`
end

main
