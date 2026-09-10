# frozen_string_literal: true

require "electra"

# Also shared by the Vulkan integration test. No vertex buffer: VertexIndex
# chooses three clip-space positions, so a vkCmdDraw(3, 1, 0, 0) suffices.
module Electra
  module ExampleShaders
    module_function

    def triangle_vertex
      mod = Module.new
      mod.vertex_shader do |f|
        index = f.input(:int, builtin: :VertexIndex)
        position = f.output(:vec4, builtin: :Position)
        first = f.constant([-0.75, -0.75, 0, 1], :vec4)
        second = f.constant([0.75, -0.75, 0, 1], :vec4)
        third = f.constant([0, 0.75, 0, 1], :vec4)
        position.store(f.select(f.equal(index, 0), first, f.select(f.equal(index, 1), second, third)))
      end
      mod.to_binary
    end

    def triangle_fragment
      mod = Module.new
      mod.fragment_shader { |f| f.output(:vec4, location: 0).store(f.constant([1, 0.25, 0, 1], :vec4)) }
      mod.to_binary
    end

    def text_fragment(version: "1.0")
      mod = Module.new(version:)
      mod.fragment_shader do |f|
        uv = f.input(:vec2, location: 0)
        tint = f.input(:vec4, location: 1)
        tex = f.sampled_image_2d(set: 0, binding: 0)
        output = f.output(:vec4, location: 0)
        alpha = f.sample(tex, uv).component(:r)
        output.store(f.mul(tint, f.splat(alpha)))
      end
      mod.to_binary
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "fileutils"
  destination = ARGV.fetch(0, "tmp/shaders")
  FileUtils.mkdir_p(destination)
  %i[triangle_vertex triangle_fragment text_fragment].each do |name|
    binary = Electra::ExampleShaders.public_send(name)
    File.binwrite(File.join(destination, "#{name}.spv"), binary)
    File.write(File.join(destination, "#{name}.spvasm"), Electra.disassemble(binary))
    puts "#{name}: #{binary.bytesize} bytes"
  end
end
