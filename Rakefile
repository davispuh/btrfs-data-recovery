# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'yard'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

YARD::Rake::YardocTask.new(:doc) do |t|
    t.files   = ['lib/**/*.rb', '-', '*.md']
end
