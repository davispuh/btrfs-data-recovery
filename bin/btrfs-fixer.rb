#!/usr/bin/env ruby

require_relative '../lib/btrfs/cli'

exit(Btrfs::Cli.main(ARGV))
