# frozen_string_literal: true

module Electra
  # Immutable structural type metadata; IDs are local to its owner module.
  Type = Data.define(:id, :kind, :element, :length, :members, :owner) do
    # @return [Integer] numeric SPIR-V type identifier
    def to_i = id
    # @return [Type] vector element type, or self for other types
    def scalar = kind == :vector ? element : self
  end
end
