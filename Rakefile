# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"

Rake::TestTask.new(:test) do |test|
  test.libs << "lib" << "test"
  test.pattern = "test/**/*_test.rb"
end

namespace :test do
  Rake::TestTask.new(:oracle) do |test|
    test.libs << "lib" << "test"
    test.pattern = "test/spirv_conformance_test.rb"
  end
end

desc "Measure performance (BUDGET=1 enables assertions)"
task :bench do
  Dir["bench/*.rb"].sort.each { |path| ruby "--yjit", "-Ilib", path }
end

desc "Build, install and smoke-test without application or development gems"
task :isolation do
  ruby "script/check_isolation.rb"
end
task default: [:test, :isolation]
