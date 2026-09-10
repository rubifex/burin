# frozen_string_literal: true

module Electra
  # Immutable SSA value or typed variable pointer, tied to one module/function.
  class Value
    attr_reader :owner, :function, :type, :id, :storage

    def initialize(owner, function, type, id, storage = nil)
      @owner, @function, @type, @id, @storage = owner, function, type, id, storage
      freeze
    end

    # @return [Integer] numeric SPIR-V identifier
    def to_i = id
    # @return [Value] loaded SSA value, or self for an existing SSA value
    def load
      return self unless storage
      function.result("OpLoad", type, id)
    end

    # Store a type-compatible value into a writable variable.
    # @return [self]
    def store(value)
      raise Error, "cannot store to #{storage || 'an SSA value'}" unless %i[Output Function Private].include?(storage)
      item = function.value(value, type)
      function.emit("OpStore", id, item.id)
      self
    end

    # @param index [Integer, Symbol] vector index or rgba/xyzw component
    # @return [Value] extracted scalar
    def component(index)
      raise Error, "component needs a function-local value" unless function
      index = {r: 0, g: 1, b: 2, a: 3, x: 0, y: 1, z: 2, w: 3}.fetch(index, index)
      raise Error, "component index out of bounds" unless type.kind == :vector && index.is_a?(Integer) && index.between?(0, type.length - 1)
      function.result("OpCompositeExtract", type.element, load.id, index)
    end
  end
end
