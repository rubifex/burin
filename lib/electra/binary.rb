# frozen_string_literal: true

require_relative "grammar"

module Electra
  # Grammar-driven instruction encoding and strict binary framing. Semantic
  # validation is deliberately the job of spirv-val, not a second compiler.
  module Binary
    # SPIR-V binary header magic.
    MAGIC = 0x07230203
    # Universal maximum ID bound from the SPIR-V specification.
    MAX_BOUND = 0x3fffff
    module_function

    def word(value)
      raise Error, "expected an unsigned 32-bit word: #{value.inspect}" unless value.is_a?(Integer) && value.between?(0, 0xffffffff)
      value
    end

    def string_words(value)
      raise Error, "SPIR-V strings must be UTF-8 without NUL" unless value.is_a?(String) && value.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !value.include?("\0")
      bytes = value.b + "\0"
      (bytes + "\0" * ((-bytes.bytesize) % 4)).unpack("V*")
    end

    # Encode the SPIR-V textual string escaping rules (not JSON escaping).
    def quote(value)
      '"' + value.gsub(/["\\]/) { |character| "\\#{character}" } + '"'
    end

    def unquote(token)
      raise Error, "unterminated string" unless token.end_with?('"') && token.length >= 2
      token[1...-1].gsub(/\\([\s\S])/) { Regexp.last_match(1) }
    end

    def enum(kind, value)
      category, entries = OPERAND_KINDS.fetch(kind)
      return [word(value), []] if value.is_a?(Integer) && !entries.values.any? { |entry| entry[0] == value }
      if value.is_a?(Integer)
        names = if category == "BitEnum" && value != 0
          entries.select { |_, (number, _)| number != 0 && (value & number) == number }.keys
        else
          [entries.key(entries.values.find { |entry| entry[0] == value })]
        end
      else
        names = value.to_s.split("|")
      end
      raise Error, "invalid #{kind}: #{value.inspect}" if names.empty? || (category != "BitEnum" && names.size != 1)
      number = 0
      parameters = []
      names.each do |name|
        entry = entries[name] or raise Error, "unknown #{kind} #{name}"
        number |= entry[0]
        parameters.concat(entry[1])
      end
      [number, parameters]
    end

    def encode(name, values)
      opcode, schema = INSTRUCTIONS.fetch(name.to_s) { raise Error, "unknown instruction #{name}" }
      words = encode_operands(name, schema, values)
      raise Error, "instruction too long" if words.size >= 0xffff
      [(words.size + 1) << 16 | opcode, *words]
    end

    def encode_operands(name, schema, values)
      words = []
      index = 0
      walk = lambda do |operands|
        operands.each do |kind, quantifier|
          count = quantifier == "*" ? values.size - index : 1
          count = 0 if quantifier == "?" && index == values.size
          count.times do
            raise Error, "missing #{kind} in #{name}" if index >= values.size
            category, = OPERAND_KINDS.fetch(kind)
            if category == "Composite"
              walk.call(OPERAND_KINDS.fetch(kind)[2].map { |base| [base, ""] })
              break if quantifier == "*" && index == values.size
              next
            end
            value = values[index]
            index += 1
            case category
            when "Id"
              value = value.to_i if value.respond_to?(:to_i) && !value.is_a?(String)
              raise Error, "invalid id #{value.inspect}" unless value.is_a?(Integer) && value.between?(1, MAX_BOUND - 1)
              words << value
            when "ValueEnum", "BitEnum"
              number, parameters = enum(kind, value)
              words << number
              walk.call(parameters)
            else
              if kind == "LiteralString"
                words.concat(string_words(value))
              elsif kind == "LiteralSpecConstantOpInteger"
                number = value.is_a?(Integer) ? value : INSTRUCTIONS.fetch("Op#{value.to_s.delete_prefix('Op')}") { raise Error, "unknown specialization opcode" }[0]
                words << word(number)
                definition = fetch_spec_opcode(number)
                walk.call(definition[1].reject { |operand, _| ["IdResultType", "IdResult"].include?(operand) })
              elsif kind == "LiteralFloat" && !value.is_a?(Integer)
                words << float_bits(Float(value))
              elsif kind == "LiteralContextDependentNumber" && value.is_a?(Array)
                words.concat(value.map { |item| word(item) })
              else
                words << word(value)
              end
            end
          end
        end
      end
      walk.call(schema)
      raise Error, "extra operands in #{name}" unless index == values.size
      words
    end

    def read(binary)
      raise Error, "SPIR-V must be a word-aligned binary String" unless binary.is_a?(String) && binary.bytesize >= 20 && binary.bytesize % 4 == 0
      little = binary.unpack1("V") == MAGIC
      words = binary.unpack(little ? "V*" : "N*")
      raise Error, "invalid SPIR-V magic" unless words[0] == MAGIC
      version = words[1]
      raise Error, "unsupported SPIR-V version" unless (version & 0xff0000ff).zero? && (version >> 16) == 1 && ((version >> 8) & 255) <= 6
      raise Error, "invalid id bound" unless words[3].between?(1, MAX_BOUND)
      raise Error, "reserved schema must be zero" unless words[4].zero?

      [words.first(5), read_instructions(words), little]
    end

    def read_instructions(words)
      instructions = []
      offset = 5
      while offset < words.size
        count, opcode = words[offset] >> 16, words[offset] & 0xffff
        raise Error, "invalid instruction length at word #{offset}" if count.zero? || count > words.size - offset
        raise Error, "unknown opcode #{opcode}" unless OPCODES.key?(opcode)
        instructions << [opcode, words.slice(offset + 1, count - 1)]
        offset += count
      end
      instructions
    end

    def decode(opcode, words, bound:, types: {})
      name, schema = OPCODES.fetch(opcode)
      tokens, result = decode_operands(name, schema, words, bound:, types:)
      record_type_declaration(types, name, words)
      types[[:import, words[0]]] = unquote(tokens[0]) if name == "OpExtInstImport"
      [name, tokens, result]
    end

    def decode_operands(name, schema, words, bound:, types:)
      tokens = []
      index = 0
      result = nil
      result_type = nil
      take = lambda do
        raise Error, "truncated #{name}" if index >= words.size
        value = words[index]
        index += 1
        value
      end
      walk = lambda do |operands|
        operands.each do |kind, quantifier|
          loop do
            break if ["?", "*"].include?(quantifier) && index == words.size
            category, entries, bases = OPERAND_KINDS.fetch(kind)
            if category == "Composite"
              walk.call(bases.map { |base| [base, ""] })
            elsif kind == "LiteralString"
              tokens << decode_string(take)
            elsif kind == "LiteralContextDependentNumber"
              tokens << decode_number(take, types[result_type])
            else
              number = take.call
              if category == "Id"
                raise Error, "id #{number} outside bound #{bound}" unless number.between?(1, bound - 1)
                result_type = number if kind == "IdResultType"
                if kind == "IdResult"
                  result = "%#{number}"
                else
                  tokens << "%#{number}"
                end
              elsif ["ValueEnum", "BitEnum"].include?(category)
                selected = if category == "BitEnum" && number != 0
                  entries.select { |_, (value, _)| value != 0 && (number & value) == value }
                else
                  entries.select { |_, (value, _)| value == number }.first(1).to_h
                end
                matched = selected.values.reduce(0) { |mask, (value, _)| mask | value }
                if selected.empty? || matched != number
                  tokens << number.to_s
                else
                  tokens << selected.keys.join("|")
                  selected.each_value { |_, parameters| walk.call(parameters) }
                end
              else
                if kind == "LiteralSpecConstantOpInteger"
                  definition = fetch_spec_opcode(number)
                  tokens << definition[0].delete_prefix("Op")
                  walk.call(definition[1].reject { |operand, _| ["IdResultType", "IdResult"].include?(operand) })
                elsif kind == "LiteralExtInstInteger" && types[[:import, words[2]]] == "GLSL.std.450"
                  tokens << (GLSL_INSTRUCTIONS.key(number) || number.to_s)
                elsif kind == "LiteralFloat"
                  tokens << float_text(number, 32)
                else
                  tokens << number.to_s
                end
              end
            end
            break unless quantifier == "*"
          end
        end
      end
      walk.call(schema)
      raise Error, "extra words in #{name}" unless index == words.size
      [tokens, result]
    end

    def decode_string(take)
      bytes = +"".b
      loop do
        chunk = [take.call].pack("V")
        nul = chunk.index("\0")
        if nul
          raise Error, "nonzero string padding" unless chunk.bytes.drop(nul).all?(&:zero?)
          bytes << chunk.byteslice(0, nul)
          break
        end
        bytes << chunk
      end
      bytes.force_encoding(Encoding::UTF_8)
      raise Error, "invalid UTF-8 string" unless bytes.valid_encoding?
      quote(bytes)
    end

    def decode_number(take, type)
      width = type ? type[1] : 32
      raise Error, "unsupported scalar width #{width}" unless [16, 32, 64].include?(width)
      bits = take.call
      bits |= take.call << 32 if width == 64
      return float_text(bits, width) if type && type[0] == :float
      bits -= 1 << width if type && type[2] == 1 && bits[width - 1] == 1
      bits.to_s
    end

    def fetch_spec_opcode(number)
      definition = OPCODES[number] or raise Error, "unknown specialization opcode"
      raise Error, "recursive specialization instruction" if definition[1].any? { |operand, _| operand == "LiteralSpecConstantOpInteger" }
      definition
    end

    # SPIR-V's hexadecimal float syntax represents infinity/NaN with exponent
    # one above the finite range, retaining payload bits for exact round trips.
    def float_text(bits, width)
      exponent_bits, fraction_bits = {16 => [5, 10], 32 => [8, 23], 64 => [11, 52]}.fetch(width)
      sign = bits[width - 1] == 1 ? "-" : ""
      exponent = (bits >> fraction_bits) & ((1 << exponent_bits) - 1)
      fraction = bits & ((1 << fraction_bits) - 1)
      if exponent == (1 << exponent_bits) - 1
        digits = (fraction_bits + 3) / 4
        mantissa = (fraction << (digits * 4 - fraction_bits)).to_s(16).rjust(digits, "0")
        "#{sign}0x1.#{mantissa}p+#{1 << (exponent_bits - 1)}"
      elsif width == 16
        value = (exponent.zero? ? fraction : fraction + (1 << fraction_bits)) * 2.0**((exponent.zero? ? 1 : exponent) - 15 - fraction_bits)
        format("%a", sign.empty? ? value : -value)
      else
        value = [bits].pack(width == 32 ? "V" : "Q<").unpack1(width == 32 ? "e" : "E")
        format("%a", value)
      end
    end

    # Round-to-nearest, ties-to-even from Ruby's Float64. String#pack('e') on
    # some Ruby versions overflows just-above-FLT_MAX values prematurely,
    # including the nine-digit decimal spelling emitted by spirv-dis.
    def float_bits(value, width = 32)
      return [value.to_f].pack("E").unpack1("Q<") if width == 64
      exponent_bits, fraction_bits = {16 => [5, 10], 32 => [8, 23]}.fetch(width)
      source = [value.to_f].pack("E").unpack1("Q<")
      sign = (source >> 63) << (width - 1)
      exponent = source >> 52 & 0x7ff
      fraction = source & ((1 << 52) - 1)
      exponent_max = (1 << exponent_bits) - 1
      if exponent == 0x7ff
        payload = fraction >> (52 - fraction_bits)
        payload = 1 if fraction != 0 && payload.zero?
        return sign | (exponent_max << fraction_bits) | payload
      end
      return sign if exponent.zero? && fraction.zero?
      target_exponent = (exponent.zero? ? 1 : exponent) - 1023 + (1 << (exponent_bits - 1)) - 1
      mantissa = exponent.zero? ? fraction : fraction | (1 << 52)
      shift = 52 - fraction_bits + [1 - target_exponent, 0].max
      rounded = mantissa >> shift
      remainder = mantissa & ((1 << shift) - 1)
      halfway = 1 << (shift - 1)
      rounded += 1 if remainder > halfway || (remainder == halfway && rounded.odd?)
      if target_exponent <= 0
        return sign | rounded
      end
      if rounded >= 1 << (fraction_bits + 1)
        rounded >>= 1
        target_exponent += 1
      end
      return sign | (exponent_max << fraction_bits) if target_exponent >= exponent_max
      sign | (target_exponent << fraction_bits) | (rounded & ((1 << fraction_bits) - 1))
    end

    # Internal implementation of Electra.disassemble.
    def disassemble(binary)
      header, instructions, little = read(binary)
      types = {}
      lines = ["; SPIR-V", "; Version: #{header[1] >> 16}.#{header[1] >> 8 & 255}", "; Generator: #{header[2]}", "; Bound: #{header[3]}", "; Schema: #{header[4]}", "; Endian: #{little ? 'little' : 'big'}"]
      instructions.each do |opcode, words|
        name, tokens, result = decode(opcode, words, bound: header[3], types: types)
        lines << [result && "#{result} =", name, *tokens].compact.join(" ")
      end
      lines.join("\n") + "\n"
    end

    def assemble(source)
      raise Error, "assembly must be a String" unless source.is_a?(String)
      parsed_statements = statements(source)
      version, generator, bound, schema, little = parse_header(parsed_statements)
      words, max_id = encode_statements(parsed_statements)
      header = [MAGIC, version, generator, bound || max_id + 1, schema].map { |value| word(value) }
      binary = [*header, *words].pack(little ? "V*" : "N*")
      disassemble(binary) # Validate framing, operands and bounds before returning.
      binary
    end

    def parse_header(statements)
      version, generator, bound, schema, little = 0x10000, 0, nil, 0, true
      statements.each do |_, tokens|
        case tokens.first
        when /\A; Version: (\d+)\.(\d+)/ then version = ($1.to_i << 16) | ($2.to_i << 8)
        when /\A; Generator: (\d+)\s*$/ then generator = $1.to_i
        when /\A; Bound: (\d+)/ then bound = $1.to_i
        when /\A; Schema: (\d+)/ then schema = $1.to_i
        when /\A; Endian: big/ then little = false
        end
      end
      [version, generator, bound, schema, little]
    end

    def encode_statements(statements)
      types = {}
      max_id = 0
      words = statements.each_with_object([]) do |(line_number, tokens), result|
        next if tokens.first.start_with?(";")
        instruction, instruction_max_id = encode_statement(tokens, line_number, types)
        result.concat(instruction)
        max_id = [max_id, instruction_max_id].max
      rescue ArgumentError, TypeError => error
        raise Error, "line #{line_number}: #{error.message}"
      end
      [words, max_id]
    end

    def encode_statement(tokens, line_number, types)
      name, tokens = parse_instruction(tokens, line_number)
      values, max_id = parse_operands(tokens)
      record_type_declaration(types, name, values)
      types[[:import, values[0]]] = values[1] if name == "OpExtInstImport"
      resolve_context_dependent_operands(name, tokens, values, types)
      [encode(name, values), max_id]
    end

    def parse_instruction(tokens, line_number)
      result, name, operands = tokens[1] == "=" ? [tokens[0], tokens[2], tokens.drop(3)] : [nil, tokens[0], tokens.drop(1)]
      definition = INSTRUCTIONS[name] or raise Error, "unknown instruction #{name} at line #{line_number}"
      result_index = definition[1].index { |kind, _| kind == "IdResult" }
      if result_index
        raise Error, "missing result id at line #{line_number}" unless result
        operands.insert(result_index, result)
      elsif result
        raise Error, "unexpected result id at line #{line_number}"
      end
      [name, operands]
    end

    def parse_operands(tokens)
      max_id = 0
      values = tokens.map do |token|
        value = parse_operand(token)
        max_id = [max_id, value].max if token.start_with?("%")
        value
      end
      [values, max_id]
    end

    def record_type_declaration(types, name, values)
      types[values[0]] = [:float, values[1]] if name == "OpTypeFloat"
      types[values[0]] = [:int, values[1], values[2]] if name == "OpTypeInt"
    end

    def resolve_context_dependent_operands(name, tokens, values, types)
      if name == "OpExtInst" && types[[:import, values[2]]] == "GLSL.std.450" && values[3].is_a?(String)
        values[3] = GLSL_INSTRUCTIONS.fetch(values[3]) { raise Error, "unknown GLSL instruction #{values[3]}" }
      end
      if ["OpConstant", "OpSpecConstant"].include?(name)
        type = types[values[0]] or raise Error, "constant type must be declared first"
        values[2] = number_words(tokens[2], type)
      end
    end

    def parse_operand(token)
      if token.start_with?("%")
        raise Error, "only numeric ids are supported" unless token.match?(/\A%[1-9]\d*\z/)
        token.delete_prefix("%").to_i
      elsif token.start_with?('"')
        unquote(token)
      elsif token.match?(/\A-?(?:0x[\da-f]+|\d+)\z/i)
        Integer(token, 0) rescue Integer(token, 10)
      else
        token
      end
    end

    # Tokenize statements, preserving multiline strings and ignoring comments.
    def statements(source)
      result = []
      tokens = []
      line_number = 1
      first_line = 1
      source.scan(/"(?:\\[\s\S]|[^"\\])*"|;[^\r\n]*|\r?\n|[^\s;]+/).each do |token|
        if token.start_with?(";")
          result << [line_number, [token]] if tokens.empty?
        elsif token == "\n" || token == "\r\n"
          result << [first_line, tokens] unless tokens.empty?
          tokens = []
          line_number += 1
          first_line = line_number
        else
          tokens << token
          line_number += token.count("\n")
        end
      end
      result << [first_line, tokens] unless tokens.empty?
      result
    rescue ArgumentError => error
      raise Error, "invalid assembly encoding: #{error.message}"
    end

    # Encode context-dependent integer/float literal words for a scalar type.
    def number_words(token, type)
      kind, width, = type
      bits = kind == :float ? float_literal_bits(token, width) : integer_literal_bits(token, width)
      width <= 32 ? [bits] : [bits & 0xffffffff, bits >> 32]
    end

    def float_literal_bits(token, width)
      raise Error, "assembly supports 16/32/64-bit float constants" unless [16, 32, 64].include?(width)
      exponent_bits, fraction_bits = {16 => [5, 10], 32 => [8, 23], 64 => [11, 52]}.fetch(width)
      max_exponent = 1 << (exponent_bits - 1)
      match = token.match(/\A(-?)0x1(?:\.([\da-f]+))?p\+#{max_exponent}\z/i)
      return float_bits(Float(token), width) unless match

      digits = match[2] || "0"
      fraction = Integer(digits, 16) << fraction_bits
      fraction >>= digits.size * 4
      bits = (((1 << exponent_bits) - 1) << fraction_bits) | fraction
      match[1] == "-" ? bits | (1 << (width - 1)) : bits
    end

    def integer_literal_bits(token, width)
      value = Integer(token, 0) rescue Integer(token, 10)
      raise Error, "integer constant outside #{width}-bit range" unless value.between?(-(1 << (width - 1)), (1 << width) - 1)
      value & ((1 << width) - 1)
    end

    private_class_method :encode_operands, :read_instructions, :decode_operands, :decode_string,
      :decode_number, :fetch_spec_opcode, :parse_header,
      :encode_statements, :encode_statement, :parse_instruction, :parse_operands,
      :record_type_declaration, :resolve_context_dependent_operands, :parse_operand,
      :float_literal_bits, :integer_literal_bits
  end
end
