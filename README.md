# Narcissus

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://theogf.github.io/Narcissus.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://theogf.github.io/Narcissus.jl/dev)
[![Test workflow status](https://github.com/theogf/Narcissus.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/theogf/Narcissus.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/theogf/Narcissus.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/theogf/Narcissus.jl)
[![Docs workflow Status](https://github.com/theogf/Narcissus.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/theogf/Narcissus.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

A terminal UI for staring at your Julia objects. Point it at a value and walk
its fields, elements and entries one level at a time — or point it at two and
see what changed.

Built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl), with the detail
pane owing a debt to [About.jl](https://github.com/tecosaur/About.jl) and the
comparison mode to [ObjectDiff.jl](https://github.com/theogf/ObjectDiff.jl).

> **This project was vibe coded in its entirety** — every line written by an LLM
> from conversational prompts.


```julia
using Narcissus

narcissus(model)                                     # explore one object
narcissus(before, after; names=("before", "after"))  # compare two
@narcissus model.layers[2]                           # …and keep the real path
print_object(model)                                  # or just print it
```

```text
╭─  object  ───────────────────────  13 rows  ─╮╭─  detail  ───────────────────  [1]  ─╮
│  ▾run::Run = Run("exp-042", Config(0.003, 50…││path     run.losses[1]                │
│  ├─ name::String = "exp-042"                 ││type     Float64                      │
│  ├─▾config::Config = Config(0.003, 50, [:bas…││kind     primitive                    │
│  │ ├─ lr::Float64 = 0.003                    ││parts    0                            │
│  │ ├─ epochs::Int64 = 50                     ││sizeof   8 bytes                      │
│  │ └─▸tags::Vector{Symbol} = [:baseline, :ad…││super    AbstractFloat                │
│  ├─▾losses::Vector{Float64} = [2.41, 1.87, 1…││                                      │
│▌ │ ├─ [1]::Float64 = 2.41                    ││───────────────────────────────────── │
│  │ ├─ [2]::Float64 = 1.87                    ││2.41                                  │
│  │ └─ [3]::Float64 = 1.55                    ││                                      │
│  └─▾notes::Dict{Symbol, An… = Dict{Symbol, A…││                                      │
│    ├─ :host::String = "gpu-03"               ││                                      │
│    └─ :seed::Int64 = 1234                    ││                                      │
│                                              ││                                      │
╰──────────────────────────────────────────────╯╰──────────────────────────────────────╯
 ↑↓ move ←→ fold ⏎ toggle / search a anomaly M memory m view y path       run.losses[1]
```

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/theogf/Narcissus.jl")
```

## Exploring

`narcissus(obj)` opens the explorer and **returns the value under the cursor
when you quit**, so it doubles as a picker: dig down to something interesting,
press `q`, and keep it.

```julia
julia> layer = narcissus(model; name="model")
julia> layer.weights
```

| Argument | Default     | Meaning                                                    |
|:---------|:------------|:-----------------------------------------------------------|
| `name`   | `"obj"`     | Label of the root, and the prefix of every path expression |
| `expand` | `1`         | How many levels to open up front                           |
| `limit`  | `100`       | Container elements pulled in per batch                     |
| `mode`   | `:semantic` | `:semantic` or `:fields` — see below                       |

Anything else is forwarded to `Tachikoma.app`.

The right-hand pane describes whatever the cursor is on: its path, type, size,
retained bytes, supertype, field names, and how it prints. `y` copies the path
expression — `model.layers[2].weights` — straight to the clipboard, ready to
paste back into the REPL.

Use the macro and the paths name something real:

```julia
julia> @narcissus model.layers[2]     # `y` now yields model.layers[2].weights
julia> @narcissus before after        # rooted at `before` and `after`
julia> @narcissus model mode=:fields  # keywords pass straight through
```

## Finding things

`/` searches. It looks at the rows already on screen first, and when nothing
there matches it **opens the object up and keeps looking** — so a field buried
six levels down is one keystroke away, without expanding anything by hand:

```text
/ sigma_noise ⏎     →  found in o.a.inner.sigma_noise
```

Names and types are tried before rendered values. A parent's preview contains
the text of everything beneath it, so matching values first would answer "where
is `sigma`?" with the root row — technically a match, never the one you meant.
The walk is bounded (20 000 nodes) because never being obliged to read all of a
large object is the whole point.

`a` hunts **anomalies** with the same escalation — the next `NaN`, `Inf`,
`missing`, empty container, `#undef` or unreadable value, wherever it is:

```text
│  ├─▸! losses::Vector{Float64} = [1.0, NaN, 3.0]
│  ├─ ∅ empty::Vector{Int64} = Int64[]
│  └─   ok::Int64 = 7
```

## Where the memory went

`M` swaps the value column for what each row *costs*: its retained size
(`Base.summarysize`, the whole graph — not the shallow `sizeof`), its share of
its parent, and a bar.

```text
▌ ▾m::M = 391.0 KiB ▕████████▏ 100%
  ├─▸small::Vector{Int64} =      64 B ▕········▏   0%
  ├─▸big::Vector{Float64} = 391.0 KiB ▕████████▏ 100%
  └─ tag::String =      10 B ▕········▏   0%
```

The share is what makes it readable: an absolute size tells you a node is
large, the proportion tells you whether it is the *reason* its parent is. Sizes
are computed only when you ask and cached per node, because each one walks the
object.

## Comparing

`narcissus(x, y)` compares two objects. It opens with the **differing branches
expanded and the identical ones folded away**, so the shape of the difference
is the first thing you see.

```text
╭─  comparison  ──────────────────  ~8 +3 -1  ─╮╭─  detail  ──────────────────  name  ─╮
│  ▾~ before ⇄ after::Run = Run("exp-042", Co…█││status   changed                      │
│▌ ├─ ~ name::String = "exp-042" → "exp-043"  █││before   before.name                  │
│  ├─▾~ config::Config = Config(0.003, 50, [:…█││after    after.name                   │
│  │ ├─ ~ lr::Float64 = 0.003 → 0.001         █││parts    0                            │
│  │ ├─ · epochs::Int64 = 50                  █││                                      │
│  │ └─▾~ tags::Vector{Symbol} = [:baseline, …█││─── before ────────────────────────── │
│  │   ├─ · [1]::Symbol = :baseline           █││type     String                       │
│  │   ├─ · [2]::Symbol = :adamw              █││"exp-042"                             │
│  │   └─ + [3]::Symbol = :warmup             █││                                      │
│  ├─▾~ losses::Vector{Float6… = [2.41, 1.87,…█││─── after ─────────────────────────── │
│  │ ├─ · [1]::Float64 = 2.41                 █││type     String                       │
│  │ ├─ ~ [2]::Float64 = 1.87 → 1.8           █││"exp-043"                             │
│  │ ├─ · [3]::Float64 = 1.55                 █││                                      │
│  │ └─ + [4]::Float64 = 1.02                 █││                                      │
│  └─▾~ notes::Dict{Symbol, A… = Dict{Symbol,…█││                                      │
│    ├─ - :host::String = "gpu-03"            █││                                      │
│    ├─ · :seed::Int64 = 1234                 │││                                      │
╰──────────────────────────────────────────────╯╰──────────────────────────────────────╯
 ↑↓ move d next diff f fold same e expand / search m view y path ? help     before.name
```

| Marker | Colour | Meaning                     |
|:-------|:-------|:----------------------------|
| `·`    | green  | the two sides are identical |
| `~`    | red    | changed                     |
| `+`    | red    | present on the right only   |
| `-`    | red    | present on the left only    |
| `!`    | red    | values of unrelated types   |

Green means the two sides match and red means they do not. Within a changed
row, the **left** side is printed in one colour and the **right** in the other
— the same two colours the detail pane uses for the two objects. `d` and `D`
jump between differences; `e` opens every differing branch under the cursor.

Equality is structural, not `isequal`: for a `mutable struct`, `==` falls back
to `===`, so two field-by-field identical objects would otherwise read as
completely changed. Narcissus uses `isequal` where it is meaningful and walks
components where it is not, so `deepcopy(x)` compares equal to `x`.

Dictionaries and sets pair by key and by membership rather than by position, so
a reordered `Dict` does not read as entirely rewritten. Everything else pairs
positionally, and the tail of the longer side shows as added or removed.

## Two views of a value: semantic and fields

`m` flips the row under the cursor between what a value **means** and what it
**is**:

```text
╭─  object  ────────────────────────  9 rows  ─╮╭─  detail  ─────────────────────  d  ─╮
│▌ ▾d::Dict{Symbol, Int64} ·fields = Dict(:a=>…││path     d                           █│
│  ├─▸slots::Memory{UInt8} ·fields = UInt8[0xb…││type     Dict{Symbol, Int64}         █│
│  ├─▸keys::Memory{Symbol} ·fields = [:a, :b, …││kind     dictionary                  █│
│  ├─▸vals::Memory{Int64} ·fields = [1, 2, 140…││view     fields  (m: semantic)       █│
│  ├─ ndel::Int64 = 0                          ││parts    8                           █│
│  ├─ count::Int64 = 2                         ││length   2                           ││
│  ├─ age::UInt64 = 0x0000000000000003         ││keytype  Symbol                      ││
│  ├─ idxfloor::Int64 = 1                      ││valtype  Int64                       ││
│  └─ maxprobe::Int64 = 0                      ││sizeof   64 bytes                    ││
╰──────────────────────────────────────────────╯╰──────────────────────────────────────╯
 ↑↓ move ←→ fold ⏎ toggle / search a anomaly M memory m view y path      d: fields view
```

- **Semantic** — a `Dict` is its entries, a `Vector` its elements, a `Set` its
  members.
- **Fields** — a `Dict` is `slots`, `keys`, `vals`, `ndel`, `count`, `age`,
  `idxfloor`, `maxprobe`; a `Vector` is `ref` and `size`.

Rows showing storage are tagged `·fields`. The mode propagates to whatever you
open beneath them, and paths stay pasteable in both (`d.slots`, `v.ref`). Start
in either with `narcissus(x; mode=:fields)`.

A plain struct looks the same in both modes, so the toggle only shows up where
there is genuinely something else to see.

## Types and modules

Point it at a type and get a readable map of an unfamiliar package — the fields
and their types, recursively:

```julia
julia> narcissus(Run)
```

```text
Run::type = Run
├─ name::type = String
├─ cfg::type = Cfg
│  ├─ lr::type = Float64
│  └─ tags::type = Vector{Symbol}
└─ losses::type = Vector{Float64}
```

Point it at a **function** and it decomposes into its methods, with the
docstring in the detail pane:

```text
▾ components::function = components (generic function with 13 methods)
├─ (::Semantic, ::Module)::Method = components(::Semantic, m::Module) @ Narcissus …
├─ (::Semantic, ::Diff)::Method   = components(::Semantic, d::Diff) @ Narcissus …
└─ (::Semantic, ::Any)::Method    = components(::Semantic, x) @ Narcissus …
```

Point it at a **module** and the two modes become the two things you might mean:

| Mode                 | A module is…                                       |
|:---------------------|:----------------------------------------------------|
| semantic *(default)* | what it offers — its public API                     |
| fields *(`m`)*       | everything it defines — internals, imports, the lot |

```julia
julia> narcissus(SomePackage)   # a browsable API listing; press m for internals
```

A package's names are a jumble of functions, types, submodules and constants,
so `f` narrows the listing to one kind at a time.

## Printing without a terminal

For a log, a CI run, a notebook, or a look that does not deserve a full-screen
app:

```julia
julia> print_object(model; maxdepth=2)
julia> Narcissus.print_diff(before, after; names=("before", "after"))
```

`print_diff` leaves out the branches that matched — pass `all=true` to keep
them. Both take a `maxdepth`, which is what keeps them honest: the tree loads
children as it is walked, so an unbounded print would read all of a large
object.

`print_diff` is qualified above because it is not exported: EndoTree.jl and
other tree packages export a `print_diff` of their own, and so a bare one would
be ambiguous in any session that loads both. The same goes for `Diff` — reach
for them as `Narcissus.print_diff` and `Narcissus.Diff`.

## Teaching Narcissus about your types

Decomposition is an interface, not a hardcoded list of types. Three methods
make a custom type behave like a first-class container — it elides when long,
compares against another one, and flips back to its fields with `m`:

```julia
struct RingBuffer
    store::Vector{Float64}
    len::Int
end

Narcissus.has_semantic_view(::RingBuffer) = true
Narcissus.component_count(::Narcissus.Semantic, r::RingBuffer) = r.len
Narcissus.components(::Narcissus.Semantic, r::RingBuffer) =
    (Narcissus.Component("[$i]", "{}.store[$i]", r.store[i]) for i in 1:r.len)
```

```text
▾ rb::RingBuffer = RingBuffer([1.0, 2.0, 3.0, 0.0, 0.0], 3)
├─ [1]::Float64 = 1.0          @ rb.store[1]
├─ [2]::Float64 = 2.0          @ rb.store[2]
└─ [3]::Float64 = 3.0          @ rb.store[3]
```

The `{}` in a template stands in for the parent's path, so paths compose all
the way down the tree. `Narcissus.is_leaf(::MyType) = true` opts out of
exploration entirely, and `Narcissus.register_semantic!` handles ecosystems
that decide by trait rather than by type.

See **[The decomposition interface](https://theogf.github.io/Narcissus.jl/dev/20-interface)**
for the full contract — what belongs in a key, how templates compose, and what
the explorer assumes about ordering and counts.

## Keys

| Key                | Action                                             |
|:-------------------|:---------------------------------------------------|
| `↑` `k` / `↓` `j`  | Move up / down                                     |
| `→` `l`            | Expand, or step into the first child                |
| `←` `h`            | Collapse, or jump to the parent                     |
| `Enter` / `Space`  | Toggle the row under the cursor                     |
| `e` / `c`          | Expand (differences, or two levels) / collapse      |
| `PgUp` / `PgDn`    | Jump a page                                         |
| `g` / `G`          | First / last row                                    |
| `/`                | Search — on screen, then into the unread object     |
| `n` / `N`          | Next / previous match                               |
| `a` / `A`          | Next / previous anomaly (NaN, Inf, empty, #undef)   |
| `M`                | Show retained size instead of values                |
| `d` / `D`          | Next / previous difference (when comparing)         |
| `f`                | Narrow the view — hide matched branches when         |
|                    | comparing, filter by kind inside a module           |
| `m`                | Switch between the semantic and field views         |
| `Tab`              | Move focus between the tree and the detail pane     |
| `y` / `Y`          | Copy the path expression / the printed value        |
| `r`                | Re-read the selected node from the live object      |
| `?`                | Key help                                            |
| `q` / `Ctrl+C`     | Quit, returning the selected value                  |

The mouse works too: click to select, click again to fold, wheel to scroll, and
**drag the border between the panes** to resize them — right-click it to put it
back. `Ctrl+T` opens Tachikoma's theme picker (26 themes, light and dark).

## What it does with awkward objects

An object explorer meets a lot of values that do not want to be explored, so
the traversal is deliberately defensive:

- **Lazy.** Children are read only when a node is opened, so pointing Narcissus
  at a large object graph costs nothing until you walk into it. The detail pane
  renders only the lines that fit on screen, and asks for more when you scroll.
- **Cycles** are detected by identity against the values on the current path
  and marked `↺ already shown above` rather than followed.
- **Long containers** arrive `limit` at a time, with a `…` row that pulls in
  the next batch when you open it.
- **Undefined fields** show as `#undef`; a `getindex`, `getfield` or `show`
  method that throws becomes a visible marker, not a stack trace.
- **Types and modules** are leaves — their internals are deep, cyclic and never
  what you opened the explorer for.
- **Expensive questions are bounded.** Structural equality gives up after a set
  number of comparisons and reports "changed"; a deep search gives up after
  20 000 nodes. Neither will hang on a pathological object.

## Path expressions

Every row knows how to name itself as Julia code:

| Container      | Path                              |
|:---------------|:----------------------------------|
| struct field   | `run.config`                      |
| odd field name | `getfield(x, Symbol("odd name"))` |
| vector         | `v[3]`                            |
| matrix         | `m[2, 3]`                         |
| dictionary     | `d[:key]`                         |
| set            | `collect(s)[3]`                   |
| struct storage | `d.slots`, `v.ref`                |

## Acknowledgements

- **[Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)** — the terminal
  UI framework everything here is built on.
- **[About.jl](https://github.com/tecosaur/About.jl)** — `about(x)` prints a
  rich description of a value: what it is, what it costs, how it is laid out.
  Narcissus' detail pane is that idea made navigable, one row at a time.
- **[ObjectDiff.jl](https://github.com/theogf/ObjectDiff.jl)** — the recursive
  comparison that `narcissus(x, y)` grew out of, including its insight that
  `==` is the wrong question to ask about two mutable structs.

## Documentation

- [Getting started](https://theogf.github.io/Narcissus.jl/dev/) — the tour
- [The decomposition interface](https://theogf.github.io/Narcissus.jl/dev/20-interface) — teaching Narcissus your own types, and the type/module views
- [Reference](https://theogf.github.io/Narcissus.jl/dev/95-reference) — full API
