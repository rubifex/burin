# frozen_string_literal: true

require_relative "lib/electra/version"

Gem::Specification.new do |spec|
  spec.name = "electra"
  spec.version = Electra::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "A pure Ruby SPIR-V shader emitter and disassembler"
  spec.homepage = "https://github.com/noxdea/electra"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["{lib,sig}/**/*", "examples/*.rb", "README.md", "CHANGELOG.md", "LICENSE*.txt"].select { |path| File.file?(path) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}).map { |path| File.basename(path) }
  spec.require_paths = ["lib"]
end
