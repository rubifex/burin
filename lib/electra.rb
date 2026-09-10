# frozen_string_literal: true

require_relative "electra/version"
require_relative "electra/data_compat"

# Pure Ruby construction and inspection of UI vertex/fragment SPIR-V modules.
module Electra
  # Invalid shader construction, malformed binary or unsupported assembly.
  class Error < StandardError; end

  # Decode a SPIR-V module using the generated Khronos operand grammar.
  # @param binary [String] complete SPIR-V bytes, little or big endian
  # @return [String] numeric-ID assembly, including round-trip header comments
  # @raise [Error] on malformed header, framing, strings, operands or ID bounds
  def self.disassemble(binary)
    Binary.disassemble(binary)
  end

  # Assemble numeric-ID SPIR-V text without invoking an external compiler.
  # @param source [String] assembly in the format returned by {.disassemble}
  # @return [String] binary bytes
  # @raise [Error] on malformed or unsupported assembly
  def self.assemble(source)
    Binary.assemble(source)
  end
end

require_relative "electra/binary"
require_relative "electra/type"
require_relative "electra/module"
require_relative "electra/value"
require_relative "electra/function"
