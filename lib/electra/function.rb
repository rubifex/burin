# frozen_string_literal: true

module Electra
  # Small typed DSL for vertex and fragment shaders, not a general compiler.
  class Function
    attr_reader :owner, :id, :interfaces, :stage

    def initialize(owner, stage)
      @owner, @stage = owner, stage
      @interfaces = []
      @bindings = {}
      @finished = false
      @terminated = false
      @id = owner.reserve_id
      void = owner.type(:void)
      signature = owner.type([:function, :void])
      owner.emit(:functions, "OpFunction", void.id, id, :None, signature.id)
      start_block(owner.reserve_id)
    end

    # @return [Value] Input variable; specify exactly one location or builtin
    def input(type, location: nil, builtin: nil, flat: false)
      define_interface(:Input, type, location:, builtin:, flat:)
    end

    # @return [Value] writable Output variable
    def output(type, location: nil, builtin: nil)
      define_interface(:Output, type, location:, builtin:)
    end

    # @return [Value] combined sampled-image descriptor
    def sampled_image_2d(set: 0, binding: 0)
      define_descriptor(owner.type([:sampled_image]), :UniformConstant, set, binding)
    end

    # Explicit offsets/layout keep GPU ABI decisions visible to the caller.
    def uniform_buffer(*types, set: 0, binding: 0, offsets:)
      define_descriptor(owner.struct(*types, offsets:, block: true), :Uniform, set, binding)
    end

    # @return [Value] single read-only push-constant block
    def push_constant(*types, offsets:)
      raise Error, "only one push constant block is allowed per shader" if @push_constant
      @push_constant = define_global(owner.struct(*types, offsets:, block: true), :PushConstant)
      @interfaces << @push_constant.id if owner.version >= 0x10400
      @push_constant
    end

    # @return [Value] struct-member pointer; loads automatically in expressions
    def member(buffer, index)
      raise Error, "expected a struct variable" unless buffer.is_a?(Value) && buffer.storage && buffer.type.kind == :struct
      owner.identifier(buffer)
      raise Error, "buffer belongs to another function" unless buffer.function.equal?(self)
      raise Error, "member out of bounds" unless index.is_a?(Integer) && index.between?(0, buffer.type.members.length - 1)
      type = buffer.type.members[index]
      pointer = owner.type([:pointer, buffer.storage, type])
      access = result("OpAccessChain", pointer, buffer.id, constant(index, :int).id)
      Value.new(owner, self, type, access.id, buffer.storage)
    end

    # @return [Value] typed constant; infer float/int/bool or float vector if omitted
    def constant(item, type = nil)
      type ||= case item
      when true, false then :bool
      when Integer then :int
      when Numeric then :float
      when Array then "vec#{item.length}".to_sym
      else raise Error, "cannot infer constant type"
      end
      result = owner.constant(type, item)
      Value.new(owner, self, result.type, result.id)
    end

    def value(item, expected = nil)
      expected = owner.type(expected) if expected
      item = constant(item, expected) unless item.is_a?(Value)
      owner.identifier(item)
      raise Error, "value belongs to another function" if item.function && !item.function.equal?(self)
      raise Error, "type mismatch: expected #{expected.kind}, got #{item.type.kind}" if expected && expected.id != item.type.id
      item.load
    end

    # @return [Value] composite assembled from typed component values
    def construct(description, *items)
      type = owner.type(description)
      raise Error, "construct supports vectors, matrices, arrays and structs" unless %i[vector matrix array struct].include?(type.kind)
      expected = type.kind == :struct ? type.members.length : type.length
      raise Error, "wrong composite element count" unless items.length == expected
      components = items.each_with_index.map { |item, index| value(item, type.kind == :struct ? type.members[index] : type.element).id }
      result("OpCompositeConstruct", type, *components)
    end

    # @return [Value] vector containing the scalar repeated count times
    def splat(item, count = 4)
      item = value(item)
      type = owner.type([:vector, item.type, count])
      result("OpCompositeConstruct", type, *Array.new(count, item.id))
    end

    # @return [Value] vec4 sample; implicit LOD is restricted to fragments
    def sample(texture, uv, lod: nil)
      texture = value(texture)
      raise Error, "expected a sampled 2D image" unless texture.type.kind == :sampled_image
      uv = value(uv, :vec2)
      unless lod.nil?
        result("OpImageSampleExplicitLod", owner.type(:vec4), texture.id, uv.id, :Lod, value(lod, :float).id)
      else
        raise Error, "implicit texture LOD is fragment-only" unless stage == :Fragment
        result("OpImageSampleImplicitLod", owner.type(:vec4), texture.id, uv.id)
      end
    end

    # @return [Value] component-wise sum of matching numeric operands
    def add(left, right) = arithmetic(:add, left, right)
    # @return [Value] component-wise difference
    def sub(left, right) = arithmetic(:sub, left, right)
    # @return [Value] float, signed or unsigned component-wise quotient
    def div(left, right) = arithmetic(:div, left, right)
    # @return [Value] float/signed modulus or unsigned remainder
    def mod(left, right) = arithmetic(:mod, left, right)

    # @return [Value] numeric, vector/scalar or dimension-checked matrix product
    def mul(left, right)
      left = value(left)
      if right.is_a?(Numeric) && [:matrix, :vector].include?(left.type.kind) && (left.type.kind == :matrix || left.type.element.kind == :float)
        right = value(right, :float)
      else
        right = value(right, left.type) unless right.is_a?(Value)
      end
      right = value(right)
      kinds = [left.type.kind, right.type.kind]
      if kinds == [:matrix, :vector]
        raise Error, "matrix/vector dimensions differ" unless left.type.length == right.type.length && right.type.element.kind == :float
        result("OpMatrixTimesVector", left.type.element, left.id, right.id)
      elsif kinds == [:vector, :matrix]
        raise Error, "vector/matrix dimensions differ" unless left.type.length == right.type.element.length && left.type.element.kind == :float
        result("OpVectorTimesMatrix", owner.type([:vector, :float, right.type.length]), left.id, right.id)
      elsif kinds == [:matrix, :matrix]
        raise Error, "matrix dimensions differ" unless left.type.length == right.type.element.length
        result("OpMatrixTimesMatrix", owner.type([:matrix, left.type.element, right.type.length]), left.id, right.id)
      elsif [:matrix, :vector].include?(left.type.kind) && right.type.kind == :float && (left.type.kind == :matrix || left.type.element.kind == :float)
        result(left.type.kind == :matrix ? "OpMatrixTimesScalar" : "OpVectorTimesScalar", left.type, left.id, right.id)
      elsif left.type.kind == :float && [:matrix, :vector].include?(right.type.kind)
        mul(right, left)
      else
        arithmetic(:mul, left, right)
      end
    end

    def negate(item)
      item = value(item)
      raise Error, "negation requires signed numeric type" unless %i[float int].include?(item.type.scalar.kind)
      result(item.type.scalar.kind == :float ? "OpFNegate" : "OpSNegate", item.type, item.id)
    end

    def dot(left, right)
      left = value(left)
      right = value(right, left.type)
      raise Error, "dot requires float vectors" unless left.type.kind == :vector && left.type.element.kind == :float
      result("OpDot", owner.type(:float), left.id, right.id)
    end

    def transpose(item)
      item = value(item)
      raise Error, "transpose requires a matrix" unless item.type.kind == :matrix
      type = owner.type([:matrix, [:vector, :float, item.type.length], item.type.element.length])
      result("OpTranspose", type, item.id)
    end

    def convert(item, description)
      item = value(item)
      type = owner.type(description)
      from, to = item.type.scalar.kind, type.scalar.kind
      raise Error, "conversion dimensions differ" unless item.type.length == type.length
      return item if item.type.id == type.id
      opcode = {[:float, :int] => "OpConvertFToS", [:float, :uint] => "OpConvertFToU", [:int, :float] => "OpConvertSToF", [:uint, :float] => "OpConvertUToF", [:int, :uint] => "OpBitcast", [:uint, :int] => "OpBitcast"}[[from, to]]
      raise Error, "unsupported conversion" unless opcode
      result(opcode, type, item.id)
    end

    # @return [Value] scalar/vector equality (ordered for floating-point inputs)
    def equal(left, right) = compare(:equal, left, right)
    # @return [Value] scalar/vector ordered inequality
    def not_equal(left, right) = compare(:not_equal, left, right)
    # @return [Value] component-wise less-than comparison
    def less_than(left, right) = compare(:less_than, left, right)
    # @return [Value] component-wise less-than-or-equal comparison
    def less_equal(left, right) = compare(:less_equal, left, right)
    # @return [Value] component-wise greater-than comparison
    def greater_than(left, right) = compare(:greater_than, left, right)
    # @return [Value] component-wise greater-than-or-equal comparison
    def greater_equal(left, right) = compare(:greater_equal, left, right)

    # @return [Value] component-wise boolean conjunction
    def logical_and(left, right) = logical("OpLogicalAnd", left, right)
    # @return [Value] component-wise boolean disjunction
    def logical_or(left, right) = logical("OpLogicalOr", left, right)
    def logical_not(item)
      item = value(item)
      raise Error, "logical operation requires bool" unless item.type.scalar.kind == :bool
      result("OpLogicalNot", item.type, item.id)
    end

    def select(condition, yes, no)
      condition = value(condition)
      yes = value(yes)
      no = value(no, yes.type)
      expected = yes.type.kind == :vector ? owner.type([:vector, :bool, yes.type.length]) : owner.type(:bool)
      condition = splat(condition, yes.type.length) if condition.type.kind == :bool && yes.type.kind == :vector
      raise Error, "select condition has incompatible type" unless condition.type.id == expected.id
      result("OpSelect", yes.type, condition.id, yes.id, no.id)
    end

    # Branch callbacks may return a value; matching results become an OpPhi.
    # With no returned value this is ordinary structured conditional control.
    def if_else(condition, yes, no = nil)
      condition = value(condition, :bool)
      then_id, else_id, merge_id = 3.times.map { owner.reserve_id }
      emit("OpSelectionMerge", merge_id, :None)
      emit("OpBranchConditional", condition.id, then_id, else_id)
      then_value, then_label, then_reachable = build_branch(then_id, merge_id) { yes.call(self) }
      else_value, else_label, else_reachable = build_branch(else_id, merge_id) { no&.call(self) }
      start_block(merge_id)
      if then_reachable && else_reachable && then_value.is_a?(Value) && else_value.is_a?(Value)
        raise Error, "branch result types differ" unless then_value.type.id == else_value.type.id
        result("OpPhi", then_value.type, then_value.id, then_label, else_value.id, else_label)
      elsif !then_reachable && !else_reachable
        emit("OpUnreachable")
        nil
      end
    end

    def discard
      raise Error, "discard is fragment-only" unless stage == :Fragment
      emit("OpKill")
      nil
    end

    # Discard the fragment when the scalar boolean condition is true.
    # @return [nil]
    def discard_if(condition)
      if_else(condition, ->(function) { function.discard })
      nil
    end

    # Terminate the current block with a void return.
    # @return [nil]
    def return_void
      emit("OpReturn")
      nil
    end

    # GLSL.std.450 operations needed for UI gradients, clipping and transforms.
    def ext(operation, *items)
      names = {round: "Round", abs: "FAbs", floor: "Floor", ceil: "Ceil", fract: "Fract", sin: "Sin", cos: "Cos", pow: "Pow", exp: "Exp", log: "Log", sqrt: "Sqrt", inverse_sqrt: "InverseSqrt", min: "FMin", max: "FMax", clamp: "FClamp", mix: "FMix", step: "Step", smoothstep: "SmoothStep", length: "Length", normalize: "Normalize"}
      arities = {pow: 2, min: 2, max: 2, clamp: 3, mix: 3, step: 2, smoothstep: 3}
      name = names[operation] or raise Error, "unknown GLSL operation #{operation}"
      opcode = GLSL_INSTRUCTIONS.fetch(name)
      raise Error, "wrong GLSL operand count" unless items.length == arities.fetch(operation, 1)
      first = value(items.first)
      raise Error, "GLSL operation requires float scalar/vector" unless first.type.scalar.kind == :float
      operands = [first, *items.drop(1).map { |item| value(item, first.type) }]
      type = operation == :length ? owner.type(:float) : first.type
      result("OpExtInst", type, owner.import("GLSL.std.450"), opcode, *operands.map(&:id))
    end

    def emit(opcode, *operands)
      raise Error, "function already finished" if @finished
      raise Error, "cannot emit after block terminator" if @terminated
      owner.emit(:functions, opcode, *operands)
      @terminated = true if %w[OpBranch OpBranchConditional OpSwitch OpKill OpReturn OpReturnValue OpUnreachable].include?(opcode)
      self
    end

    # Low-level typed instruction with an automatically allocated result ID.
    # @return [Value]
    def result(opcode, type, *operands)
      type = owner.type(type)
      id = owner.reserve_id
      emit(opcode, type.id, id, *operands)
      Value.new(owner, self, type, id)
    end

    # Close the function, inserting a return for an unterminated block.
    # @return [self]
    def finish
      return self if @finished
      emit("OpReturn") unless @terminated
      owner.emit(:functions, "OpFunctionEnd")
      @finished = true
      self
    end

    def finished? = @finished

    private

    def build_branch(label_id, merge_id)
      start_block(label_id)
      branch_value = yield
      branch_label = @current_label
      reachable = !@terminated
      branch_value = value(branch_value) if reachable && branch_value.is_a?(Value)
      emit("OpBranch", merge_id) if reachable
      [branch_value, branch_label, reachable]
    end

    def start_block(id)
      owner.emit(:functions, "OpLabel", id)
      @current_label = id
      @terminated = false
    end

    def define_interface(storage, description, location: nil, builtin: nil, flat: false)
      raise Error, "provide exactly one of location or builtin" unless location.nil? != builtin.nil?
      type = owner.type(description)
      key = [storage, location, builtin]
      raise Error, "duplicate shader interface" if @bindings[key]
      @bindings[key] = true
      variable = define_global(type, storage)
      owner.decorate(variable, :Location, location) unless location.nil?
      owner.decorate(variable, :BuiltIn, builtin) unless builtin.nil?
      owner.decorate(variable, :Flat) if flat
      @interfaces << variable.id
      variable
    end

    def define_descriptor(type, storage, set, binding)
      key = [set, binding]
      raise Error, "duplicate descriptor binding" if @bindings[key]
      @bindings[key] = true
      variable = define_global(type, storage)
      owner.decorate(variable, :DescriptorSet, set)
      owner.decorate(variable, :Binding, binding)
      @interfaces << variable.id if owner.version >= 0x10400
      variable
    end

    def define_global(type, storage)
      pointer = owner.type([:pointer, storage, type])
      id = owner.reserve_id
      owner.emit(:declarations, "OpVariable", pointer.id, id, storage)
      Value.new(owner, self, type, id, storage)
    end

    def arithmetic(operation, left, right)
      left = value(left)
      right = value(right, left.type)
      kind = left.type.scalar.kind
      raise Error, "arithmetic requires numeric scalars or vectors" unless %i[float int uint].include?(kind)
      codes = {add: %w[OpFAdd OpIAdd OpIAdd], sub: %w[OpFSub OpISub OpISub], mul: %w[OpFMul OpIMul OpIMul], div: %w[OpFDiv OpSDiv OpUDiv], mod: %w[OpFMod OpSMod OpUMod]}
      result(codes.fetch(operation)[%i[float int uint].index(kind)], left.type, left.id, right.id)
    end

    def compare(operation, left, right)
      left = value(left)
      right = value(right, left.type)
      kind = left.type.scalar.kind
      endings = {equal: "Equal", not_equal: "NotEqual", less_than: "LessThan", less_equal: "LessThanEqual", greater_than: "GreaterThan", greater_equal: "GreaterThanEqual"}
      prefix = case kind
      when :float then "FOrd"
      when :int then %i[equal not_equal].include?(operation) ? "I" : "S"
      when :uint then %i[equal not_equal].include?(operation) ? "I" : "U"
      when :bool
        raise Error, "booleans are not ordered" unless %i[equal not_equal].include?(operation)
        "Logical"
      else raise Error, "comparison requires scalars or vectors"
      end
      type = left.type.kind == :vector ? owner.type([:vector, :bool, left.type.length]) : owner.type(:bool)
      result("Op#{prefix}#{endings.fetch(operation)}", type, left.id, right.id)
    end

    def logical(opcode, left, right)
      left = value(left)
      right = value(right, left.type)
      raise Error, "logical operation requires bool" unless left.type.scalar.kind == :bool
      result(opcode, left.type, left.id, right.id)
    end
  end
end
