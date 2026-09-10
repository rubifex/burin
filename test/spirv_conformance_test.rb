# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/example_shaders"
require "open3"
require "tmpdir"

class SPIRVConformanceTest < Minitest::Test
  def setup
    @tools = %w[spirv-val spirv-dis spirv-as].to_h do |name|
      suffixes = Gem.win_platform? ? [".exe", ""] : [""]
      path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map { |directory| suffixes.map { |suffix| File.join(directory, name + suffix) } }.find { |file| File.executable?(file) && !File.directory?(file) }
      [name, path]
    end
    unless @tools.values.all?
      flunk "required SPIRV-Tools are missing" if ENV["SPIRV_TOOLS_REQUIRED"] == "1"
      skip "SPIRV-Tools are not installed"
    end
  end

  def validate(binary, version: "1.0")
    Dir.mktmpdir("spirv-oracle") do |directory|
      file = File.join(directory, "shader.spv")
      File.binwrite(file, binary)
      target = {"1.0" => "vulkan1.0", "1.3" => "vulkan1.1", "1.4" => "vulkan1.1spv1.4", "1.5" => "vulkan1.2", "1.6" => "vulkan1.3"}.fetch(version)
      output, status = Open3.capture2e(@tools.fetch("spirv-val"), "--target-env", target, file)
      assert status.success?, "spirv-val: #{output}\n#{Electra.disassemble(binary)}"
      native, status = Open3.capture2e(@tools.fetch("spirv-dis"), "--raw-id", "--no-indent", "--no-header", file)
      assert status.success?, native
      ours = Electra.disassemble(binary)
      # Compare complete instructions/operands after canonicalizing float text.
      native_binary = Electra.assemble(native)
      assert_equal binary.byteslice(20..), native_binary.byteslice(20..), "spirv-dis semantic output differs"
      assert_equal binary, Electra.assemble(ours)
      text_path = File.join(directory, "shader.spvasm")
      rebuilt_path = File.join(directory, "rebuilt.spv")
      File.write(text_path, ours)
      output, status = Open3.capture2e(@tools.fetch("spirv-as"), "--preserve-numeric-ids", "--target-env", "spv#{version}", text_path, "-o", rebuilt_path)
      assert status.success?, "spirv-as: #{output}"
      assert_equal binary.byteslice(20..), File.binread(rebuilt_path).byteslice(20..), "spirv-as produced different instruction words"
    end
  end

  def test_texture_and_triangle_all_target_versions
    %i[text_fragment triangle_vertex triangle_fragment].each { |method| validate(Electra::ExampleShaders.public_send(method)) }
    %w[1.3 1.4 1.5 1.6].each { |version| validate(Electra::ExampleShaders.text_fragment(version:), version:) }
  end

  def test_all_arithmetic_comparisons_logic_select_and_conversions
    mod = Electra::Module.new
    mod.fragment_shader do |f|
      output = f.output(:vec4, location: 0)
      %i[float int uint vec4 ivec4 uvec4].each do |type|
        composite = type.to_s.include?("vec")
        a, b = f.constant(composite ? [1, 2, 3, 4] : 1, type), f.constant(composite ? [4, 3, 2, 1] : 2, type)
        %i[add sub mul div mod].each { |operation| f.public_send(operation, a, b) }
        %i[equal not_equal less_than less_equal greater_than greater_equal].each { |operation| f.select(f.public_send(operation, a, b), a, b) }
        f.negate(a) unless %i[uint uvec4].include?(type)
        f.convert(a, composite ? :vec4 : :float)
      end
      %i[bool bvec4].each do |type|
        a, b = f.constant(type == :bool ? true : [true] * 4, type), f.constant(type == :bool ? false : [false] * 4, type)
        f.logical_and(a, b)
        f.logical_or(a, b)
        f.logical_not(a)
        f.equal(a, b)
        f.not_equal(a, b)
      end
      f.convert(f.constant(1.0), :int)
      f.convert(f.constant(1.0), :uint)
      f.convert(f.constant(-1), :uint)
      f.convert(f.constant(1, :uint), :int)
      output.store(f.constant([1, 1, 1, 1]))
    end
    validate(mod.to_binary)
  end

  def test_structured_branches_phi_nested_and_discard
    mod = Electra::Module.new
    mod.fragment_shader do |f|
      alpha = f.input(:float, location: 0)
      output = f.output(:vec4, location: 0)
      f.discard_if(f.less_than(alpha, 0.1))
      result = f.if_else(f.less_than(alpha, 0.5),
        ->(branch) { branch.if_else(branch.less_than(alpha, 0.25), ->(inner) { inner.constant(0.1) }, ->(inner) { inner.constant(0.2) }) },
        ->(branch) { branch.mul(alpha, 0.9) })
      output.store(f.splat(result))
    end
    validate(mod.to_binary)
    mod = Electra::Module.new
    mod.fragment_shader do |f|
      f.if_else(f.constant(true), ->(branch) { branch.discard }, ->(branch) { branch.return_void })
    end
    validate(mod.to_binary)
  end

  def test_matrices_buffers_arrays_push_constants_and_glsl
    mod = Electra::Module.new
    mod.vertex_shader do |f|
      input = f.input(:vec4, location: 0)
      output = f.output(:vec4, builtin: :Position)
      buffer = f.uniform_buffer(:mat4, mod.array(:vec4, 2, stride: 16), set: 0, binding: 0, offsets: [0, 64])
      mod.member_decorate(buffer.type, 0, :ColMajor)
      mod.member_decorate(buffer.type, 0, :MatrixStride, 16)
      push = f.push_constant(:vec4, offsets: [0])
      matrix = f.member(buffer, 0)
      f.mul(input, matrix)
      f.transpose(matrix)
      f.mul(matrix, matrix)
      f.mul(matrix, 2.0)
      f.mul(input, 2.0)
      f.dot(input, input)
      f.ext(:length, input)
      f.ext(:normalize, input)
      %i[round abs floor ceil fract sin cos exp log sqrt inverse_sqrt].each { |name| f.ext(name, input) }
      %i[pow min max step].each { |name| f.ext(name, input, input) }
      %i[clamp mix smoothstep].each { |name| f.ext(name, input, input, input) }
      output.store(f.add(f.mul(matrix, input), f.member(push, 0)))
    end
    validate(mod.to_binary)
  end

  def test_vertex_sampling_uses_explicit_lod
    mod = Electra::Module.new
    mod.vertex_shader do |f|
      uv = f.input(:vec2, location: 0)
      tex = f.sampled_image_2d
      output = f.output(:vec4, builtin: :Position)
      assert_raises(Electra::Error) { f.sample(tex, uv) }
      output.store(f.sample(tex, uv, lod: 0.0))
    end
    validate(mod.to_binary)
  end

  def test_float_special_values_and_integer_boundaries
    mod = Electra::Module.new
    mod.fragment_shader do |f|
      [Float::NAN, Float::INFINITY, -Float::INFINITY, 0.0, -0.0, 1e-40, 3.4028234663852886e38].each { |value| f.constant(value) }
      [-0x80000000, -1, 0, 0x7fffffff].each { |value| f.constant(value, :int) }
      f.constant(0xffffffff, :uint)
    end
    validate(mod.to_binary)
  end

  def test_debug_strings_and_multiple_entry_points
    mod = Electra::Module.new
    mod.name(mod.type(:float), "日本語; newline\nquote\"slash\\tab\t")
    mod.vertex_shader("vertex") { |f| f.output(:vec4, builtin: :Position).store(f.constant([0, 0, 0, 1])) }
    mod.fragment_shader("fragment") { |f| f.output(:vec4, location: 0).store(f.constant([1, 1, 1, 1])) }
    validate(mod.to_binary)
  end
end
