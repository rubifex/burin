<h1 align="center">Electra</h1>

<p align="center">
  <strong>Pure Ruby SPIR-V emitter, typed shader DSL, assembler, and disassembler</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/electra"><img src="https://img.shields.io/gem/v/electra.svg" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/electra"><img src="https://img.shields.io/gem/dt/electra.svg" alt="Gem downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby version">
  <a href="https://github.com/noxdea/electra/actions/workflows/main.yml"><img src="https://github.com/noxdea/electra/actions/workflows/main.yml/badge.svg" alt="CI status"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#shader-dsl">Shader DSL</a> ·
  <a href="#assembly-and-low-level-api">Assembly</a> ·
  <a href="#development">Development</a>
</p>

---

Electra builds the small shaders a UI renderer needs directly from Ruby, without running GLSL compilers or loading native bindings. Use it when a Vulkan application needs to ship shader construction as Ruby source. It is not a GLSL compiler, optimizer, or complete SPIR-V semantic validator.

## Features

- Typed vertex and fragment shader DSL for UI renderers
- Pure Ruby with no runtime gem dependencies
- SPIR-V 1.0–1.6 binary emission
- Numeric-ID assembler and disassembler with byte-for-byte round trips
- Explicit uniform, push-constant, array, and matrix layouts
- Grammar tables derived from a pinned Khronos SPIRV-Headers revision

## Installation

Add Electra to your bundle:

```sh
bundle add electra
```

Or install it directly:

```sh
gem install electra
```

### Requirements

- Ruby 3.1 or newer
- SPIRV-Tools is optional and only used for development validation

## Quick Start

Build a fragment shader and inspect its SPIR-V assembly:

```ruby
require "electra"

mod = Electra::Module.new
mod.fragment_shader do |f|
  output = f.output(:vec4, location: 0)
  output.store(f.constant([1, 0, 0, 1]))
end

binary = mod.to_binary
puts Electra.disassemble(binary)
```

Generate the bundled triangle and text shader examples from a checkout:

```sh
ruby -Ilib examples/example_shaders.rb tmp/shaders
```

The triangle vertex shader uses `VertexIndex`, so the consumer can issue `vkCmdDraw(3, 1, 0, 0)` without a vertex buffer. Both entry points are named `main`; the fragment output is location 0.

## Shader DSL

This texture shader samples an alpha channel and multiplies it by a vertex tint:

```ruby
mod = Electra::Module.new(version: "1.0", generator: 0)

mod.fragment_shader("main") do |f|
  uv = f.input(:vec2, location: 0)
  tint = f.input(:vec4, location: 1)
  texture = f.sampled_image_2d(set: 0, binding: 0)
  output = f.output(:vec4, location: 0)
  alpha = f.sample(texture, uv).component(:r)
  output.store(f.mul(tint, f.splat(alpha)))
end

binary = mod.to_binary
raise "round trip failed" unless Electra.assemble(Electra.disassemble(binary)) == binary
```

`Shader`, `Logical/GLSL450`, `OriginUpperLeft` for fragments, and function return instructions are added automatically. `to_binary` returns a little-endian binary String with an exact ID bound and schema zero. The application must select a SPIR-V version supported by its Vulkan environment. SPIR-V 1.4+ descriptor and push-constant variables are included in entry-point interfaces.

### Types and operations

Scalar types are `:bool`, `:int`, `:uint`, and `:float` (32-bit numbers). Vectors are `:vec2`–`:vec4`, `:ivecN`, `:uvecN`, and `:bvecN`. Matrices `:mat2`–`:mat4` and `:matCxR` are column-major floating-point matrices. `mod.array(type, count, stride:)` and `mod.struct(*types, offsets:, block:)` expose explicit aggregate layout. Struct and matrix constants use nested arrays, one array per column.

Types are structurally interned; constants are interned by type and exact bit pattern, including negative zero. `f.constant(value, type)` creates a typed constant. Numeric literals passed alongside a typed operand use its type; use `1.0` for an inferred float and `1` for an inferred signed integer.

| Operation | API |
| --- | --- |
| Inputs/outputs | `input(type, location:)`, `output(type, location:)`; alternatively `builtin: :Position` / `:VertexIndex`; input `flat: true` |
| Components/composites | `value.component(:r)` / `component(0)`, `construct(type, *components)`, `splat(scalar, count = 4)` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `mod`, `negate`; scalar/vector numeric types |
| Matrices | `mul` selects matrix×matrix, matrix×vector, vector×matrix, or scalar multiplication; `transpose`, `dot` |
| Conversion | `convert(value, type)` for numeric scalar/vector conversion; int/uint conversion is bit-preserving |
| Comparison | `equal`, `not_equal`, `less_than`, `less_equal`, `greater_than`, `greater_equal` |
| Boolean/selection | `logical_and`, `logical_or`, `logical_not`, `select(condition, yes, no)` |
| Texture | `sampled_image_2d(set:, binding:)`, `sample(texture, uv, lod: nil)`; explicit LOD required outside fragments |
| Control flow | `if_else(condition, then_callback, else_callback = nil)`, `discard`, `discard_if`, `return_void` |
| GLSL.std.450 | `ext(:clamp, value, lower, upper)`, plus round/abs/floor/ceil/fract/sin/cos/pow/exp/log/sqrt/inverse_sqrt/min/max/mix/step/smoothstep/length/normalize |

Inputs and descriptors load automatically when consumed; output variables use `store`. Types and values cannot cross module boundaries, and function-local values cannot cross function boundaries. Integer fragment inputs should be declared `flat: true` as required by Vulkan.

### Structured control flow

Structured branches allocate forward labels and merge matching returned values with `OpPhi`:

```ruby
alpha = f.input(:float, location: 0)
f.discard_if(f.less_than(alpha, 0.01))
adjusted = f.if_else(f.less_than(alpha, 0.5),
  ->(branch) { branch.mul(alpha, 0.5) },
  ->(branch) { branch.mul(alpha, 0.9) })
f.output(:vec4, location: 0).store(f.splat(adjusted))
```

### Uniform and push-constant layout

Offsets and strides are explicit: the emitter does not guess a CPU/GPU ABI.

```ruby
mod.vertex_shader do |f|
  input = f.input(:vec4, location: 0)
  output = f.output(:vec4, builtin: :Position)
  buffer = f.uniform_buffer(:mat4, set: 0, binding: 0, offsets: [0])
  push = f.push_constant(:vec4, offsets: [0])

  mod.member_decorate(buffer.type, 0, :ColMajor)
  mod.member_decorate(buffer.type, 0, :MatrixStride, 16)
  output.store(f.add(f.mul(f.member(buffer, 0), input), f.member(push, 0)))
end
```

`decorate(target, decoration, *values)` supports the grammar's decorations, including Location, Binding, DescriptorSet, Block, and ArrayStride. `member_decorate(type, index, decoration, *values)` handles Offset and matrix layout. Repeating the same decoration is harmless; conflicting values raise `Electra::Error`.

## Assembly and low-level API

`Electra.disassemble(binary)` validates the header, instruction framing, operands, strings, and ID bounds. `Electra.assemble(text)` accepts numeric `%123` IDs and SPIR-V instruction syntax. Output from the disassembler round-trips byte-for-byte, preserving version, generator, bound, and endianness through header comments. Floating-point hexadecimal spelling preserves 16/32/64-bit constants, signed zero, and NaN payloads.

For instructions outside the DSL, `mod.reserve_id` / `mod.ref(:label)` reserve forward IDs, and `mod.emit(section, "OpName", id, "name")` accepts grammar-order operands. Sections are emitted in specification order. Every reserved ID must be defined exactly once. The low-level API does not validate dominance, capability requirements, or storage-layout rules: run `spirv-val`.

The opcode, enum, and GLSL.std.450 tables are derived from a pinned [Khronos SPIRV-Headers revision](https://github.com/KhronosGroup/SPIRV-Headers/tree/496543121ce6419f23d6fa5d7194ba66c36212d2/include/spirv/unified1).

### Supported scope and limits

The typed DSL intentionally covers UI vertex and fragment shaders only. Compute, tessellation, geometry, subgroups, ray tracing, GLSL parsing, optimization, and GPU resource management are not implemented.

The assembler and disassembler are not a general replacement for SPIRV-Tools. Nonnumeric ID names, other extended-instruction symbolic vocabularies, and context-dependent 64-bit `OpSwitch` literals are outside the supported round-trip surface. No binary is claimed valid merely because it can be disassembled; the Vulkan implementation and, during development, `spirv-val` check full shader semantics and GPU limits.

Errors are reported as `Electra::Error`; discard a builder after a failed mutation. Module and function objects own mutable construction state, so use one builder per thread. Type and value records and generated grammar tables are frozen. Independent builders share no allocation counters or shader state.

## Development

```sh
bundle install
bundle exec rake                     # tests and isolated install
bundle exec rake test:oracle         # requires SPIRV-Tools; skips if absent
BUDGET=1 bundle exec rake bench       # 10 ms regression guard
rbs -I sig validate
```

Tests cover malformed and truncated binaries, 1,000 seeded binary mutations, type and constant interning, forward references, exact assembly round trips, float boundaries, and strings. When installed, `spirv-val`, `spirv-dis`, and `spirv-as` validate complete emitted instruction streams across SPIR-V 1.0, 1.3, 1.4, 1.5, and 1.6. Linux CI requires these external checks; macOS and Windows skip them when the tools are unavailable.

A Vulkan draw/readback test belongs to the renderer consuming the shared triangle shaders. SPIRV-Tools tests alone do not prove a rendered image.

### Performance

Measured locally on arm64 macOS with Ruby 4.0.0 and YJIT; 604-byte text fragment, median of five runs of 1,000 operations:

| Workload | Time | Allocated objects |
| --- | ---: | ---: |
| Build and serialize text fragment | 170.37 µs | 1,532 |
| Disassemble | 108.82 µs | 959 |
| Assemble | 205.05 µs | 1,653 |

Shaders are intended to be built once and retained, not rebuilt per frame. Rerun `bench/emitter.rb` on the target Ruby and platform; these are measurements, not universal guarantees.

## Contributing

Bug reports and pull requests are welcome at <https://github.com/noxdea/electra>.

## Name

“Electra” is the engraving tool that cuts precise lines into metal: this library similarly engraves SPIR-V instructions. The RubyGems name is `electra`; the Ruby namespace is `Electra`.

## License

Electra is released under the [MIT License](LICENSE.txt). Khronos grammar and derived tables retain their [upstream license](LICENSE-SPIRV-Headers.txt).

Protocol references: [SPIR-V registry](https://registry.khronos.org/SPIR-V/), [Vulkan SPIR-V environment](https://docs.vulkan.org/spec/latest/appendices/spirvenv.html), and [GLSL.std.450](https://registry.khronos.org/SPIR-V/specs/unified1/GLSL.std.450.html).
