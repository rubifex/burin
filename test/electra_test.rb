# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/example_shaders"

class ElectraTest < Minitest::Test
  def test_design_example_and_triangle_round_trip
    %i[text_fragment triangle_vertex triangle_fragment].each do |name|
      binary = Electra::ExampleShaders.public_send(name)
      assert_equal binary, Electra.assemble(Electra.disassemble(binary))
      assert_equal 0x07230203, binary.unpack1("V")
      assert_equal 0, binary.unpack("V*")[4]
    end
  end

  def test_structural_types_and_constants_are_unique
    mod = Electra::Module.new
    assert_same mod.type(:vec4), mod.type([:vector, :float, 4])
    assert_same mod.type([:pointer, :Input, :vec4]), mod.type([:pointer, :Input, [:vector, :float, 4]])
    assert_same mod.type(:mat4), mod.type([:matrix, :vec4, 4])
    assert_same mod.constant(:float, 1), mod.constant(:float, 1.0)
    refute_same mod.constant(:float, 0.0), mod.constant(:float, -0.0)
    assert_same mod.constant(:vec4, [1, 2, 3, 4]), mod.constant(:vec4, [1.0, 2.0, 3.0, 4.0])
    assert_same mod.struct(:vec4, offsets: [0], block: true), mod.struct(:vec4, offsets: [0], block: true)
    refute_same mod.array(:vec4, 2, stride: 16), mod.array(:vec4, 2, stride: 32)
    binary = mod.to_binary
    text = Electra.disassemble(binary)
    assert_equal 1, text.scan(/OpTypeFloat/).length
    assert_equal binary, Electra.assemble(text)
  end

  def test_forward_ids_sections_and_decorations
    mod = Electra::Module.new
    target = mod.ref(:later)
    assert_equal target, mod.ref(:later)
    mod.name(target, "before definition")
    mod.decorate(target, :ArrayStride, 16)
    mod.extension("SPV_KHR_storage_buffer_storage_class")
    mod.capability(:Shader)
    mod.import("GLSL.std.450")
    assert_raises(Electra::Error) { mod.to_binary }
    element = mod.type(:vec4)
    length = mod.constant(:uint, 3)
    mod.emit(:declarations, "OpTypeArray", target, element.id, length.id)
    text = Electra.disassemble(mod.to_binary)
    names = text.lines.reject { |line| line.start_with?(";") }.map { |line| line[/Op\w+/] }
    assert_equal %w[OpCapability OpExtension OpExtInstImport OpMemoryModel OpName OpDecorate], names.first(6)
    assert_raises(Electra::Error) { mod.emit(:declarations, "OpTypeVoid", target) }
    assert_raises(Electra::Error) { mod.decorate(target, :ArrayStride, 32) }
  end

  def test_float_payloads_and_signed_constants
    mod = Electra::Module.new
    [0.0, -0.0, 1.5, 1e-40, Float::INFINITY, -Float::INFINITY, Float::NAN].each { |number| mod.constant(:float, number) }
    [-0x80000000, -1, 0, 0x7fffffff].each { |number| mod.constant(:int, number) }
    mod.constant(:uint, 0xffffffff)
    binary = mod.to_binary
    assert_equal binary, Electra.assemble(Electra.disassemble(binary))
    big = binary.unpack("V*").pack("N*")
    assert_equal big, Electra.assemble(Electra.disassemble(big))
    100.times do |seed|
      bits = Random.new(seed).rand(0x100000000)
      source = "; Bound: 3\n%1 = OpTypeFloat 32\n%2 = OpConstant %1 #{Electra::Binary.float_text(bits, 32)}\n"
      assert_equal bits, Electra.assemble(source).unpack("V*").last
    end
  end

  def test_strings_and_bitmask_parameters
    mod = Electra::Module.new
    float = mod.type(:float)
    mod.name(float, "日本語; quoted \"x\" \\ newline\n")
    binary = mod.to_binary
    assert_equal binary, Electra.assemble(Electra.disassemble(binary))
    words = Electra::Binary.encode("OpLoad", [1, 2, 3, "Volatile|Aligned", 16])
    name, tokens, id = Electra::Binary.decode(words.first & 0xffff, words.drop(1), bound: 4)
    assert_equal "OpLoad", name
    assert_equal ["%1", "%3", "Volatile|Aligned", "16"], tokens
    assert_equal "%2", id
  end

  def test_scalar_widths_specialization_constants_and_float_rounding
    [16, 32, 64].each do |width|
      [0, 1, (1 << (width - 1)), (1 << width) - 1].each do |bits|
        source = "; Bound: 3\n%1 = OpTypeFloat #{width}\n%2 = OpConstant %1 #{Electra::Binary.float_text(bits, width)}\n"
        binary = Electra.assemble(source)
        expected = width <= 32 ? [bits] : [bits & 0xffffffff, bits >> 32]
        assert_equal expected, binary.unpack("V*").last(expected.length)
        assert_equal binary, Electra.assemble(Electra.disassemble(binary))
      end
    end
    source = "%1 = OpTypeInt 64 1\n%2 = OpConstant %1 -9223372036854775808\n%3 = OpConstant %1 9223372036854775807\n%4 = OpSpecConstantOp %1 IAdd %2 %3\n"
    binary = Electra.assemble(source)
    assert_equal binary, Electra.assemble(Electra.disassemble(binary))
    assert_equal 0x7f7fffff, Electra::Binary.float_bits(3.40282347e38)
    assert_equal 0x7f800000, Electra::Binary.float_bits(3.40282357e38)
    assert_equal 0x3f800000, Electra::Binary.float_bits(1.0 + 2.0**-24)
    assert_equal 0x3f800002, Electra::Binary.float_bits(1.0 + 3 * 2.0**-24)
    assert_equal 0, Electra::Binary.float_bits(2.0**-150)
    assert_equal 2, Electra::Binary.float_bits(3 * 2.0**-150)
  end

  def test_invalid_binary_and_assembly_are_rejected
    good = Electra::ExampleShaders.triangle_fragment
    invalid = [nil, "", "not a binary", good.byteslice(0, 19), good + "x"]
    [0, 1, 3, 4, 5].each do |index|
      words = good.unpack("V*")
      words[index] = {0 => 0, 1 => 0x20000, 3 => 0, 4 => 1, 5 => 0}.fetch(index)
      invalid << words.pack("V*")
    end
    invalid << [0x07230203, 0x10000, 0, 3, 0, (3 << 16) | 5, 1, 0x41414141].pack("V*")
    invalid.each { |binary| assert_raises(Electra::Error) { Electra.disassemble(binary) } }
    ["OpNoSuch", "%1 = OpTypeFloat", "%1 = OpTypeFloat 32 0 0", "OpCapability Nope", "%name = OpTypeVoid", "OpTypeVoid", "%1 = OpReturn", "; Bound: 1\n%1 = OpTypeVoid"].each do |source|
      assert_raises(Electra::Error) { Electra.assemble(source) }
    end
  end

  def test_typed_dsl_rejects_invalid_inputs
    assert_raises(Electra::Error) { Electra::Module.new(version: "2.0") }
    mod = Electra::Module.new
    [:vec5, :wat, nil, [:vector, :void, 4]].each { |type| assert_raises(Electra::Error) { mod.type(type) } }
    assert_raises(Electra::Error) { mod.type(Electra::Module.new.type(:float)) }
    assert_raises(Electra::Error) { mod.constant(:int, 0x80000000) }
    assert_raises(Electra::Error) { mod.constant(:vec4, [1, 2]) }
    mod.fragment_shader do |f|
      input = f.input(:vec4, location: 0)
      assert_raises(Electra::Error) { f.input(:vec4, location: 0) }
      assert_raises(Electra::Error) { f.input(:vec4) }
      assert_raises(Electra::Error) { input.store(f.constant([1, 1, 1, 1])) }
      assert_raises(Electra::Error) { input.component(4) }
      assert_raises(Electra::Error) { f.add(input, f.constant(1)) }
      assert_raises(Electra::Error) { f.less_than(true, false) }
      assert_raises(Electra::Error) { f.sample(input, [0, 0]) }
      assert_raises(Electra::Error) { f.construct(:vec4, 1.0) }
      assert_raises(Electra::Error) { f.constant(1).store(2) }
      f.return_void
      assert_raises(Electra::Error) { f.add(1.0, 2.0) }
    end
  end

  def test_deterministic_binary_mutation_fuzz
    original = Electra::ExampleShaders.text_fragment
    random = Random.new(3418)
    1000.times do
      words = original.unpack("V*")
      words[random.rand(words.length)] = random.rand(0x100000000)
      binary = words.pack("V*")
      begin
        text = Electra.disassemble(binary)
        assert_equal binary, Electra.assemble(text)
      rescue Electra::Error
        assert true
      end
    end
  end

  def test_independent_builders_are_thread_safe_and_tables_are_immutable
    expected = Electra::ExampleShaders.text_fragment
    results = 4.times.map { Thread.new { 25.times.map { Electra::ExampleShaders.text_fragment } } }.flat_map(&:value)
    results.each { |binary| assert_equal expected, binary }
    assert_raises(FrozenError) { Electra::INSTRUCTIONS.fetch("OpTypeFloat")[1] << ["bad", ""] }
    assert_raises(FrozenError) { Electra::OPERAND_KINDS.fetch("Capability")[1]["bad"] = [123, []] }
  end
end
