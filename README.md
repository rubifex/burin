# Electra

A pure Ruby SPIR-V shader emitter, typed vertex/fragment DSL, assembler and disassembler.

Electra builds the small shaders a UI renderer needs directly from Ruby, without running GLSL compilers or loading native bindings. Use it when a Vulkan application needs to ship shader construction as Ruby source. It is not a GLSL compiler, optimizer, or complete SPIR-V semantic validator.

Requires Ruby 3.1+. No runtime gem dependencies; the library also works with `ruby --disable-gems`. SPIRV-Tools are optional development oracles, never runtime requirements.

## Try it

```ruby
require "electra"
mod = Electra::Module.new
mod.fragment_shader { |f| f.output(:vec4, location: 0).store(f.constant([1, 0, 0, 1])) }
binary = mod.to_binary
puts Electra.disassemble(binary)
```

Install the gem:

```sh
gem install electra
```

Or build it from this checkout:

```sh
gem build electra.gemspec
gem install --local electra-0.1.0.gem
ruby -Ilib examples/example_shaders.rb tmp/shaders
```

The example emits a no-vertex-buffer triangle pair and a text fragment shader. `Electra::ExampleShaders.triangle_vertex` uses `VertexIndex`, so the consumer can issue `vkCmdDraw(3, 1, 0, 0)`. Both entry points are named `main`; the fragment output is location 0.

## Text shader

```ruby
mod = Electra::Module.new(version: "1.0", generator: 0)
mod.capability :Shader
mod.memory_model :Logical, :GLSL450

mod.fragment_shader("main") do |f|
  uv = f.input(:vec2, location: 0)
  tint = f.input(:vec4, location: 1)
  tex = f.sampled_image_2d(set: 0, binding: 0)
  output = f.output(:vec4, location: 0)
  alpha = f.sample(tex, uv).component(:r)
  output.store(f.mul(tint, f.splat(alpha)))
end

binary = mod.to_binary
raise "round trip failed" unless Electra.assemble(Electra.disassemble(binary)) == binary
```

`Shader`, `Logical/GLSL450`, `OriginUpperLeft` for fragments, and function return instructions are added automatically. Calling `capability` again is harmless. `to_binary` returns a little-endian binary String, with an exact ID bound and schema zero. Versions 1.0–1.6 are accepted; the application must select a version supported by its Vulkan environment. SPIR-V 1.4+ descriptor/push-constant variables are included in entry-point interfaces.

## Types and operations

Scalar types are `:bool`, `:int`, `:uint`, `:float` (32-bit numbers). Vectors are `:vec2`–`:vec4`, and `:ivecN`, `:uvecN`, `:bvecN`. Matrices `:mat2`–`:mat4` and `:matCxR` are column-major floating-point matrices. `mod.array(type, count, stride:)` and `mod.struct(*types, offsets:, block:)` expose explicit aggregate layout. Struct/matrix constants use nested arrays, one array per column.

Types are structurally interned; constants are interned by their type and exact bit pattern, including negative zero. `f.constant(value, type)` creates a typed constant. Numeric literals passed alongside a typed operand use its type; use `1.0` for an inferred float and `1` for an inferred signed integer.

| Operation | API |
| --- | --- |
| Inputs/outputs | `input(type, location:)`, `output(type, location:)`; alternatively `builtin: :Position` / `:VertexIndex`; input `flat: true` |
| Components/composites | `value.component(:r)` / `component(0)`, `construct(type, *components)`, `splat(scalar, count = 4)` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `mod`, `negate`; scalar/vector numeric types |
| Matrices | `mul` selects matrix×matrix, matrix×vector, vector×matrix or scalar multiplication; `transpose`, `dot` |
| Conversion | `convert(value, type)` for numeric scalar/vector conversion; int/uint conversion is bit-preserving |
| Comparison | `equal`, `not_equal`, `less_than`, `less_equal`, `greater_than`, `greater_equal` |
| Boolean/selection | `logical_and`, `logical_or`, `logical_not`, `select(condition, yes, no)` |
| Texture | `sampled_image_2d(set:, binding:)`, `sample(texture, uv, lod: nil)`; explicit LOD required outside fragments |
| Control flow | `if_else(condition, then_callback, else_callback = nil)`, `discard`, `discard_if`, `return_void` |
| GLSL.std.450 | `ext(:clamp, value, lower, upper)`, plus round/abs/floor/ceil/fract/sin/cos/pow/exp/log/sqrt/inverse_sqrt/min/max/mix/step/smoothstep/length/normalize |

Inputs and descriptors load automatically when consumed; output variables use `store`. Types and values cannot cross module boundaries, and function-local values cannot cross function boundaries. Integer fragment inputs should be declared `flat: true` as required by Vulkan.

Structured branches allocate forward labels and merge matching returned values with `OpPhi`:

```ruby
alpha = f.input(:float, location: 0)
f.discard_if(f.less_than(alpha, 0.01))
adjusted = f.if_else(f.less_than(alpha, 0.5),
  ->(branch) { branch.mul(alpha, 0.5) },
  ->(branch) { branch.mul(alpha, 0.9) })
f.output(:vec4, location: 0).store(f.splat(adjusted))
```

## Uniform and push-constant layout

Offsets/strides are explicit: the emitter does not guess a CPU/GPU ABI.

```ruby
buffer = f.uniform_buffer(:mat4, set: 0, binding: 0, offsets: [0])
mod.member_decorate(buffer.type, 0, :ColMajor)
mod.member_decorate(buffer.type, 0, :MatrixStride, 16)
position.store(f.mul(f.member(buffer, 0), input_position))
# f.push_constant(:vec4, offsets: [0]) returns a read-only struct variable.
```

`decorate(target, decoration, *values)` supports the grammar's decorations, including Location, Binding, DescriptorSet, Block and ArrayStride. `member_decorate(type, index, decoration, *values)` handles Offset and matrix layout. Repeating the same decoration is harmless; conflicting values raise `Electra::Error`.

For instructions outside the DSL, `mod.reserve_id` / `mod.ref(:label)` reserve forward IDs, and `mod.emit(section, "OpName", id, "name")` accepts grammar-order operands. Sections are emitted in specification order: capabilities, extensions, imports, memory model, entry points, execution modes, debug, annotations, declarations, functions. Every reserved ID must be defined exactly once. The low-level API does not validate dominance, capability requirements or storage-layout rules: run `spirv-val`.

## Assembly and limits

`Electra.disassemble(binary)` validates the header, instruction framing, operands, strings and ID bounds. `Electra.assemble(text)` accepts numeric `%123` IDs and SPIR-V instruction syntax; output from this disassembler round-trips byte-for-byte, preserving version, generator, bound and endianness through header comments. Strings use SPIR-V escaping (only quote/backslash need escaping; embedded line breaks remain literal). Floating-point hexadecimal spelling preserves 16/32/64-bit constants, signed zero and NaN payloads.

The complete opcode/enum table and GLSL.std.450 names are derived from a pinned [Khronos SPIRV-Headers revision](https://github.com/KhronosGroup/SPIRV-Headers/tree/496543121ce6419f23d6fa5d7194ba66c36212d2/include/spirv/unified1). The typed DSL intentionally covers UI vertex and fragment shaders only. Compute, tessellation, geometry, subgroups, ray tracing, GLSL parsing, optimization and GPU resource management are not implemented. The assembler/disassembler is not a general replacement for SPIRV-Tools: nonnumeric ID names, other extended-instruction symbolic vocabularies, and context-dependent 64-bit `OpSwitch` literals are outside its supported round-trip surface.

Errors are `Electra::Error`; builders should be discarded after a failed mutation. No binary is claimed valid merely because it can be disassembled. GPU limits and full shader semantics are checked by the actual Vulkan implementation and, in development, `spirv-val`.

Module/Function objects own mutable construction state; use one builder per thread. Type/Value records and generated grammar tables are frozen. Independent builders share no allocation counters or shader state.

## Verification and performance

```sh
bundle install
bundle exec rake                    # tests and isolated install
bundle exec rake test:oracle         # requires SPIRV-Tools; skips if absent
BUDGET=1 bundle exec rake bench      # 10ms regression guard, not a frame-time target
rbs -I sig validate
```

The independent tests include malformed/truncated binaries, 1,000 seeded binary mutations, type/constant interning, forward references, exact assembly round trips, float boundaries and strings. When installed, `spirv-val`, `spirv-dis` and `spirv-as` check complete emitted instruction streams, including comparisons, nested branches/phi/discard, matrix operations, buffer layout, explicit LOD and GLSL intrinsics across SPIR-V 1.0/1.3/1.4/1.5/1.6. Linux CI installs these tools; macOS/Windows skip only external oracles when unavailable. A Vulkan draw/readback test belongs to the renderer consuming the shared triangle shader pair; this library's SPIRV-Tools tests alone do not prove a rendered image.

Measured locally on arm64 macOS, Ruby 4.0.0 + YJIT; 604-byte text fragment, median of five runs of 1,000 operations:

| Workload | Time | Allocated objects |
| --- | ---: | ---: |
| Build and serialize text fragment | 170.37 µs | 1,532 |
| Disassemble | 108.82 µs | 959 |
| Assemble | 205.05 µs | 1,653 |

Shaders are intended to be built once and retained, not rebuilt per frame. Rerun `bench/emitter.rb` on the target Ruby/platform; these are measurements, not universal guarantees.

## Name and license

“Electra” is the engraving tool that cuts precise lines into metal: this library similarly engraves SPIR-V instructions. The RubyGems name is `electra`, namespace `Electra`.

MIT; see [LICENSE.txt](LICENSE.txt). Khronos grammar and derived tables retain their [upstream license](LICENSE-SPIRV-Headers.txt). Protocol references: [SPIR-V registry](https://registry.khronos.org/SPIR-V/), [Vulkan SPIR-V environment](https://docs.vulkan.org/spec/latest/appendices/spirvenv.html), [GLSL.std.450](https://registry.khronos.org/SPIR-V/specs/unified1/GLSL.std.450.html).
