# frozen_string_literal: true

require_relative "../examples/example_shaders"

iterations = Integer(ENV.fetch("N", "1000"))
raise "N must be positive" unless iterations.positive?
binary = Electra::ExampleShaders.text_fragment
assembly = Electra.disassemble(binary)
workloads = {
  "build text fragment" => -> { Electra::ExampleShaders.text_fragment },
  "disassemble" => -> { Electra.disassemble(binary) },
  "assemble" => -> { Electra.assemble(assembly) }
}
puts "#{RUBY_DESCRIPTION}; #{binary.bytesize} bytes; #{iterations} iterations; median of 5"
workloads.each do |name, work|
  100.times { work.call }
  times = 5.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { work.call }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / iterations
  end
  GC.start
  before = GC.stat(:total_allocated_objects)
  iterations.times { work.call }
  allocations = (GC.stat(:total_allocated_objects) - before).to_f / iterations
  median = times.sort[2] * 1_000_000
  puts format("%-22s %9.2f us/op  %8.1f objects/op", name, median, allocations)
  # A regression guard, not a product latency promise; shaders are built once.
  abort "#{name} exceeded 10ms budget" if ENV["BUDGET"] == "1" && median > 10_000
end
