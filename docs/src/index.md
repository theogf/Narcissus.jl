```@meta
CurrentModule = Narcissus
```

# Narcissus

A terminal UI for staring at your Julia objects. Point it at a value and walk
its fields, elements and entries one level at a time — or point it at two and
see what changed.

Built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl).

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

## Getting a value back out

[`narcissus`](@ref) returns whatever the cursor is on when you quit, so the
explorer doubles as a picker:

```julia
julia> layer = narcissus(model; name="model")   # navigate, then press q
julia> layer.weights
```

The `name` keyword is both the label of the root row and the prefix of every
path expression in the detail pane — pass the variable's real name and `y`
gives you something you can paste straight back into the REPL. Better, let
[`@narcissus`](@ref) capture it:

```julia
julia> @narcissus model.layers[2]     # `y` now yields model.layers[2].weights
```

## Finding things

`/` looks at the rows already on screen first, and when nothing matches it
**opens the object up and keeps looking** — so a field buried six levels down
is one keystroke away:

```text
/ sigma_noise ⏎     →  found in o.a.inner.sigma_noise
```

Names and types are tried before rendered values, because a parent's preview
contains the text of everything beneath it and would otherwise answer every
query with the root row. The walk is bounded by [`SEARCH_BUDGET`](@ref) nodes:
never being obliged to read all of a large object is the whole point of the
lazy tree.

`a` hunts [`anomaly`](@ref) rows the same way — the next `NaN`, `Inf`,
`missing`, empty container, `#undef` or unreadable value, wherever it is.

## Where the memory went

`M` swaps the value column for what each row costs: its retained size
(`Base.summarysize`, not the shallow `sizeof`), its share of its parent, and a
bar.

```text
▌ ▾m::M = 391.0 KiB ▕████████▏ 100%
  ├─▸small::Vector{Int64} =      64 B ▕········▏   0%
  ├─▸big::Vector{Float64} = 391.0 KiB ▕████████▏ 100%
  └─ tag::String =      10 B ▕········▏   0%
```

An absolute size tells you a node is large; the share tells you whether it is
the *reason* its parent is. Computed on request and cached, since each answer
walks the object.

## Types and modules

`narcissus(SomeType)` shows the fields and their types, recursively — a
readable map of an unfamiliar package. `narcissus(SomePackage)` shows a
module's public API, `m` drops into everything it defines, and `f` narrows the
listing to functions, types, submodules or values in turn.

A function decomposes into its methods, and its docstring goes in the detail
pane — as do a type's and a module's. See [the interface page](@ref interface)
for how all of this is just [`components`](@ref) methods.

## Printing without a terminal

[`print_object`](@ref) and [`print_diff`](@ref) render the same trees to any
`IO` — for a log, a CI run, or a notebook. Both take a `maxdepth`, which is
what keeps them from reading all of a large object.

```julia
julia> print_diff(before, after; names=("before", "after"))
```

## Comparing two objects

[`narcissus(x, y)`](@ref narcissus) opens with the differing branches expanded
and the identical ones folded away, so the shape of the difference is the first
thing you see.

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

Green means the two sides match and red means they do not; within a changed row
the left side is printed in one colour and the right in the other. `d` and `D`
jump between differences.

Equality is [`same_value`](@ref), not `isequal`: for a `mutable struct` `==`
falls back to `===`, so two field-by-field identical objects would otherwise
read as completely changed. Dictionaries and sets pair by key and by
membership, everything else positionally.

A comparison is not a special mode bolted on — it is a [`Diff`](@ref) value
that implements the same [decomposition interface](@ref interface) everything
else does, which is why laziness, elision, cycle detection and the `m` toggle
all work on it unchanged.

## Two views of a value

`m` flips the row under the cursor between what a value **means** (a `Dict` is
its entries) and what it **is** (a `Dict` is `slots`, `keys`, `vals`, `ndel`,
`count`, `age`, `idxfloor`, `maxprobe`). Rows showing storage are tagged
`·fields`, and the mode propagates to whatever you open beneath them.

Start in either with `narcissus(x; mode=:fields)`. See
[The decomposition interface](@ref interface) for teaching your own types how
to decompose.

## Keys

| Key                | Action                                              |
|:-------------------|:----------------------------------------------------|
| `↑` `k` / `↓` `j`  | Move up / down                                      |
| `→` `l`            | Expand, or step into the first child                |
| `←` `h`            | Collapse, or jump to the parent                     |
| `Enter` / `Space`  | Toggle the row under the cursor                     |
| `e` / `c`          | Expand (differences, or two levels) / collapse      |
| `PgUp` / `PgDn`    | Jump a page                                         |
| `g` / `G`          | First / last row                                    |
| `/`                | Search — on screen, then into the unread object     |
| `n` / `N`          | Next / previous match                               |
| `a` / `A`          | Next / previous anomaly                             |
| `M`                | Show retained size instead of values                |
| `d` / `D`          | Next / previous difference (when comparing)         |
| `f`                | Narrow the view — hide matched branches, or filter a module |
| `m`                | Switch between the semantic and field views         |
| `Tab`              | Move focus between the tree and the detail pane     |
| `y` / `Y`          | Copy the path expression / the printed value        |
| `r`                | Re-read the selected node from the live object      |
| `?`                | Key help                                            |
| `q` / `Ctrl+C`     | Quit, returning the selected value                  |

The mouse works too: click to select, click again to fold, wheel to scroll, and
drag the border between the panes to resize them — right-click it to restore the
default. `Ctrl+T` opens Tachikoma's theme picker.

## How the traversal behaves

An object explorer meets a lot of values that do not want to be explored, so
the traversal is deliberately defensive:

- **Lazy.** Children are read only when a node is opened, so pointing Narcissus
  at a large object graph costs nothing until you walk into it.
- **Cycles** are detected by identity against the values on the current path and
  marked `↺ already shown above` instead of being followed.
- **Long containers** arrive `limit` elements at a time, with a `…` row at the
  end that pulls in the next batch when you open it.
- **Undefined fields** show as `#undef`, and a `getindex`, `getfield` or `show`
  method that throws becomes a visible marker rather than a stack trace.
- **Expensive questions are bounded.** Structural equality gives up after a set
  number of comparisons; a deep search gives up after
  [`SEARCH_BUDGET`](@ref) nodes. Neither hangs on a pathological object.

## Path expressions

Every row knows how to name itself as Julia code:

| Container      | Path                                |
|:---------------|:------------------------------------|
| struct field   | `run.config`                        |
| odd field name | `getfield(x, Symbol("odd name"))`   |
| vector         | `v[3]`                              |
| matrix         | `m[2, 3]`                           |
| dictionary     | `d[:key]`                           |
| set            | `collect(s)[3]`                     |
| struct storage | `d.slots`, `v.ref`                  |

`y` copies the one under the cursor to the clipboard.

## Where to next

- [The decomposition interface](@ref interface) — teaching Narcissus your own
  types, and the two modes in detail.
- [Reference](@ref reference) — the full API.
