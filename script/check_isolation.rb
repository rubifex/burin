# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rubygems/package"

root = File.expand_path("..", __dir__)
Dir[File.join(root, "lib/**/*.rb")].each do |path|
  abort "application dependency in #{path}" if File.read(path).match?(/\b(?:Zaniah|Canopus)\b/)
end
spec = Gem::Specification.load(File.join(root, "electra.gemspec"))
abort "unexpected runtime gem dependencies" unless spec.runtime_dependencies.empty?
Dir.mktmpdir("electra-install") do |directory|
  gem_file = File.join(directory, "electra.gem")
  Dir.chdir(root) { Gem::Package.build(spec, false, false, gem_file) }
  install = File.join(directory, "gems")
  output, status = Open3.capture2e(Gem.ruby, File.join(RbConfig::CONFIG.fetch("bindir"), "gem"), "install", "--local", "--ignore-dependencies", "--no-document", "--install-dir", install, gem_file)
  abort output unless status.success?
  smoke = <<~RUBY
    require "electra"
    mod = Electra::Module.new
    mod.fragment_shader { |f| f.output(:vec4, location: 0).store(f.constant([1, 0, 0, 1])) }
    binary = mod.to_binary
    abort "round trip failed" unless Electra.assemble(Electra.disassemble(binary)) == binary
    actual = File.realpath(Gem.loaded_specs.fetch("electra").full_gem_path)
    abort "wrong gem: " + actual unless actual.start_with?(File.realpath(#{install.inspect}) + File::SEPARATOR)
    puts "isolated install: #{spec.version}, shader emitted successfully"
  RUBY
  env = {"GEM_HOME" => install, "GEM_PATH" => install, "RUBYLIB" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil}
  output, status = Open3.capture2e(env, Gem.ruby, "-e", smoke, chdir: directory)
  abort output unless status.success?
  puts output
end
