# frozen_string_literal: true

module Electra
  # Ordered SPIR-V module builder. IDs belong to a module, never a global pool.
  class Module
    # SPIR-V logical module layout order.
    SECTIONS = %i[capabilities extensions imports memory_model entry_points execution_modes debug annotations declarations functions].freeze
    attr_reader :version

    # @param version [String] SPIR-V version, 1.0 through 1.6
    # @param generator [Integer] 32-bit generator word; zero means unregistered
    def initialize(version: "1.0", generator: 0)
      major, minor = version.to_s.split(".").map(&:to_i)
      raise Error, "supported versions are 1.0 through 1.6" unless major == 1 && minor && minor.between?(0, 6) && version.to_s == "#{major}.#{minor}"
      @version = (major << 16) | (minor << 8)
      @generator = Binary.word(generator)
      @sections = SECTIONS.to_h { |section| [section, []] }
      @next_id = 1
      @types = {}
      @constants = {}
      @names = {}
      @definitions = {}
      @capabilities = {}
      @extensions = {}
      @imports = {}
      @decorations = {}
      @entries = {}
      @functions = []
      capability(:Shader)
      memory_model(:Logical, :GLSL450)
    end

    # Allocate a module-local forward ID. A named reservation is idempotent.
    # @param name [Object, nil] optional lookup key
    # @return [Integer] SSA identifier, which must later be defined exactly once
    def reserve_id(name = nil)
      return @names[name] if name && @names.key?(name)
      raise Error, "SPIR-V id limit exceeded" if @next_id >= Binary::MAX_BOUND
      id = @next_id
      @next_id += 1
      @names[name] = id if name
      id
    end
    alias ref reserve_id

    # Low-level escape hatch. Operands follow the Khronos grammar order,
    # including result type/result IDs. Reserve forward IDs with #ref first.
    def emit(section, opcode, *operands)
      buffer = @sections[section] or raise Error, "unknown section #{section}"
      words = Binary.encode(opcode.to_s, operands)
      schema = INSTRUCTIONS.fetch(opcode.to_s)[1]
      index = schema.index { |kind, _| kind == "IdResult" }
      if index
        id = operands[index].to_i
        raise Error, "id #{id} was not reserved in this module" unless id.between?(1, @next_id - 1)
        raise Error, "id #{id} already defined" if @definitions[id]
        @definitions[id] = true
      end
      buffer.concat(words)
      self
    end

    # Add a capability once, using its Khronos spelling.
    # @return [self]
    def capability(name)
      key = Binary.enum("Capability", name)[0]
      emit(:capabilities, "OpCapability", name) unless @capabilities[key]
      @capabilities[key] = true
      self
    end

    # Add an OpExtension declaration once.
    # @return [self]
    def extension(name)
      emit(:extensions, "OpExtension", name) unless @extensions[name]
      @extensions[name] = true
      self
    end

    # @return [Integer] deduplicated extended-instruction set ID
    def import(name)
      @imports[name] ||= reserve_id.tap { |id| emit(:imports, "OpExtInstImport", id, name) }
    end

    # Replace the module's single addressing/memory-model declaration.
    # @return [self]
    def memory_model(addressing = :Logical, model = :GLSL450)
      @sections[:memory_model] = Binary.encode("OpMemoryModel", [addressing, model])
      self
    end

    # Attach a debug name; does not change numeric ID allocation.
    # @return [self]
    def name(target, text)
      emit(:debug, "OpName", identifier(target), text)
    end

    # Add a decoration. Conflicting values for the same decoration are errors.
    # @return [self]
    def decorate(target, decoration, *values)
      apply_decoration("OpDecorate", identifier(target), decoration, values)
    end

    # Decorate a struct member, for example Offset or MatrixStride.
    # @return [self]
    def member_decorate(target, member, decoration, *values)
      apply_decoration("OpMemberDecorate", identifier(target), decoration, values, member)
    end

    # Resolve and structurally intern a type description.
    # @param description [Symbol, String, Array, Type] scalar/composite type
    # @return [Type] immutable type record owned by this module
    def type(description)
      if description.is_a?(Type)
        raise Error, "type belongs to another module" unless description.owner.equal?(self)
        return description
      end
      raise Error, "type must be a Symbol, String, Type or Array" unless description.is_a?(Array) || description.is_a?(Symbol) || description.is_a?(String)
      key = description.is_a?(Array) ? description.dup.freeze : description.to_sym
      return @types[key] if @types.key?(key)
      if (alias_description = expand_type_alias(key))
        return @types[key] = type(alias_description)
      end
      define_type(key, description)
    end

    # @return [Type] fixed-size array with optional explicit ArrayStride
    def array(element, length, stride: nil)
      value = type([:array, element, length, stride])
      decorate(value, :ArrayStride, stride) if stride
      value
    end

    # @return [Type] struct with optional member offsets and Block decoration
    def struct(*members, offsets: nil, block: false)
      raise Error, "one offset per struct member is required" if offsets && offsets.length != members.length
      value = type([:struct, members.freeze, nil, offsets&.freeze, block])
      decorate(value, :Block) if block
      offsets&.each_with_index { |offset, index| member_decorate(value, index, :Offset, offset) }
      value
    end

    # Intern a scalar or nested composite constant by its exact bit pattern.
    # @return [Value] module-scoped constant (not a mutable variable)
    def constant(description, value)
      value_type = type(description)
      opcode, args = constant_encoding(value_type, value)
      key = [value_type.id, opcode, *args]
      @constants[key] ||= begin
        id = reserve_id
        emit(:declarations, opcode, value_type.id, id, *args)
        Value.new(self, nil, value_type, id)
      end
    end

    # @yieldparam function [Function] fragment shader builder
    # @return [Function] completed entry point
    def fragment_shader(name = "main", &block) = define_shader(:Fragment, name, &block)
    # @yieldparam function [Function] vertex shader builder
    # @return [Function] completed entry point
    def vertex_shader(name = "main", &block) = define_shader(:Vertex, name, &block)

    # Serialize sections in specification order and reject unresolved IDs.
    # @return [String] little-endian SPIR-V bytes; retain for repeated GPU use
    def to_binary
      raise Error, "unfinished shader" unless @functions.all?(&:finished?)
      missing = (1...@next_id).reject { |id| @definitions[id] }
      raise Error, "unresolved ids: #{missing.join(', ')}" unless missing.empty?
      binary = [Binary::MAGIC, @version, @generator, @next_id, 0, *SECTIONS.flat_map { |section| @sections.fetch(section) }].pack("V*")
      Binary.disassemble(binary)
      binary
    end

    # Extract an ID after checking module ownership.
    # @return [Integer]
    def identifier(value)
      if value.respond_to?(:owner)
        raise Error, "value belongs to another module" unless value.owner.equal?(self)
      end
      value.respond_to?(:id) ? value.id : value
    end

    private

    def expand_type_alias(key)
      return unless key.is_a?(Symbol)
      if (match = key.to_s.match(/\A([biu]?)vec([2-4])\z/))
        [:vector, {"" => :float, "b" => :bool, "i" => :int, "u" => :uint}.fetch(match[1]), match[2].to_i]
      elsif (match = key.to_s.match(/\Amat([2-4])(?:x([2-4]))?\z/))
        [:matrix, "vec#{match[2] || match[1]}".to_sym, match[1].to_i]
      end
    end

    def define_type(key, description)
      element = nil
      length = nil
      members = []
      case key
      when :void then kind, opcode, args = :void, "OpTypeVoid", []
      when :bool then kind, opcode, args = :bool, "OpTypeBool", []
      when :float then kind, opcode, args = :float, "OpTypeFloat", [32]
      when :int then kind, opcode, args = :int, "OpTypeInt", [32, 1]
      when :uint then kind, opcode, args = :uint, "OpTypeInt", [32, 0]
      else
        raise Error, "unknown type #{description.inspect}" unless key.is_a?(Array)
        kind = key[0]
        case kind
        when :vector, :matrix
          element, length = type(key[1]), key[2]
          raise Error, "vector/matrix dimensions must be 2..4" unless length.is_a?(Integer) && length.between?(2, 4)
          raise Error, "invalid vector scalar" if kind == :vector && !%i[float int uint bool].include?(element.kind)
          raise Error, "matrix needs float column vectors" if kind == :matrix && !(element.kind == :vector && element.element.kind == :float)
          capability(:Matrix) if kind == :matrix
          opcode, args = kind == :vector ? ["OpTypeVector", [element.id, length]] : ["OpTypeMatrix", [element.id, length]]
        when :pointer
          element = type(key[2])
          length = key[1]
          opcode, args = "OpTypePointer", [key[1], element.id]
        when :function
          members = key.drop(1).map { |item| type(item) }
          opcode, args = "OpTypeFunction", members.map(&:id)
        when :image2d
          element = type(:float)
          opcode, args = "OpTypeImage", [element.id, :"2D", 0, 0, 0, 1, :Unknown]
        when :sampled_image
          element = type([:image2d])
          opcode, args = "OpTypeSampledImage", [element.id]
        when :array
          element, length = type(key[1]), key[2]
          raise Error, "array length must be positive" unless length.is_a?(Integer) && length.between?(1, 0xffffffff)
          opcode, args = "OpTypeArray", [element.id, constant(:uint, length).id]
        when :struct
          members = key[1].map { |item| type(item) }
          opcode, args = "OpTypeStruct", members.map(&:id)
        else
          raise Error, "unknown type #{description.inspect}"
        end
      end
      # Aliases, pointers and composites all converge on structural IDs.
      canonical = [opcode, *args, *(key.is_a?(Array) && [:array, :struct].include?(kind) ? key.drop(3) : [])].freeze
      return @types[key] = @types[canonical] if @types.key?(canonical)
      id = reserve_id
      emit(:declarations, opcode, id, *args)
      value = Type.new(id:, kind:, element:, length:, members: members.freeze, owner: self)
      @types[key] = @types[canonical] = value
    end

    def constant_encoding(value_type, value)
      case value_type.kind
      when :bool
        raise Error, "boolean constant must be true or false" unless value == true || value == false
        opcode, args = value ? ["OpConstantTrue", []] : ["OpConstantFalse", []]
      when :float
        raise Error, "float constant must be Numeric" unless value.is_a?(Numeric)
        opcode, args = "OpConstant", [Binary.float_bits(value)]
      when :int, :uint
        range = value_type.kind == :int ? (-0x80000000..0x7fffffff) : (0..0xffffffff)
        raise Error, "integer constant out of range" unless value.is_a?(Integer) && range.cover?(value)
        opcode, args = "OpConstant", [value & 0xffffffff]
      when :vector, :matrix, :array, :struct
        expected = value_type.kind == :struct ? value_type.members.length : value_type.length
        raise Error, "expected #{expected} composite elements" unless value.is_a?(Array) && value.length == expected
        args = value.each_with_index.map do |item, index|
          component_type = value_type.kind == :struct ? value_type.members[index] : value_type.element
          constant(component_type, item).id
        end
        opcode = "OpConstantComposite"
      else
        raise Error, "type cannot be a constant"
      end
      [opcode, args]
    end

    def apply_decoration(opcode, id, decoration, values, member = nil)
      number = Binary.enum("Decoration", decoration)[0]
      key = [id, member, number]
      raise Error, "conflicting #{decoration} decoration" if @decorations.key?(key) && @decorations[key] != values
      unless @decorations.key?(key)
        emit(:annotations, opcode, id, *[member].compact, decoration, *values)
        @decorations[key] = values.freeze
      end
      self
    end

    def define_shader(stage, entry_name)
      raise Error, "shader block required" unless block_given?
      raise Error, "duplicate entry point #{entry_name}" if @entries[[stage, entry_name]]
      function = Function.new(self, stage)
      @functions << function
      yield function
      function.finish
      @entries[[stage, entry_name]] = function.id
      emit(:entry_points, "OpEntryPoint", stage, function.id, entry_name, *function.interfaces)
      emit(:execution_modes, "OpExecutionMode", function.id, :OriginUpperLeft) if stage == :Fragment
      name(function.id, entry_name)
      function
    end
  end
end
