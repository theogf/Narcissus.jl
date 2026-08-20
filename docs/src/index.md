```@meta
CurrentModule = Narcissus
```

# Narcissus

A terminal UI for staring at your Julia objects. Point it at a value and walk
its fields, elements and entries one level at a time, instead of squinting at a
thousand-line `dump`.

Built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl).

```julia
using Narcissus
narcissus(my_object)
```

```text
╭─  object  ───────────────────────────  13 rows  ─╮╭─  detail  ────────────  losses  ─╮
│  ▾run::Run = Run("exp-042", Config(0.003, 50, [:…││path     run.losses              █│
│  ├─ name::String = "exp-042"                     ││type     Vector{Float64}         █│
│  ├─▾config::Config = Config(0.003, 50, [:baselin…││kind     array                   █│
│  │ ├─ lr::Float64 = 0.003                        ││size     (5,)                    █│
│  │ ├─ epochs::Int64 = 50                         ││eltype   Float64                 █│
│  │ └─▸tags::Vector{Symbol} = [:baseline, :adamw] ││sizeof   40 bytes                █│
│▌ ├─▾losses::Vector{Float64} = [2.41, 1.87, 1.55,…││super    DenseVector{Float64}    █│
│  │ ├─ [1]::Float64 = 2.41                        ││fields   ref, size               █│
│  │ ├─ [2]::Float64 = 1.87                        ││                                 █│
│  │ ├─ [3]::Float64 = 1.55                        ││─────────────────────────────────█│
│  │ ├─ [4]::Float64 = 1.31                        ││5-element Vector{Float64}:       █│
│  │ └─ [5]::Float64 = 1.12                        ││ 2.41                            █│
│  └─▸notes::Dict{Symbol, Any} = Dict{Symbol, Any}…││ 1.87                            █│
│                                                  ││ 1.55                            █│
│                                                  ││ 1.31                            ││
╰──────────────────────────────────────────────────╯╰──────────────────────────────────╯
 ↑↓ move ←→ fold ⏎ toggle / search y path ⇥ pane ? help q quit               run.losses
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
gives you something you can paste straight back into the REPL.

## Keys

| Key                | Action                                              |
|:-------------------|:----------------------------------------------------|
| `↑` `k` / `↓` `j`  | Move up / down                                      |
| `→` `l`            | Expand, or step into the first child                |
| `←` `h`            | Collapse, or jump to the parent                     |
| `Enter` / `Space`  | Toggle the row under the cursor                     |
| `e` / `c`          | Expand two levels / collapse the whole subtree      |
| `PgUp` / `PgDn`    | Jump a page                                         |
| `g` / `G`          | First / last row                                    |
| `/`                | Search the visible rows; `n` / `N` for next / prev  |
| `Tab`              | Move focus between the tree and the detail pane     |
| `y` / `Y`          | Copy the path expression / the printed value        |
| `r`                | Re-read the selected node from the live object      |
| `?`                | Key help                                            |
| `q` / `Ctrl+C`     | Quit, returning the selected value                  |

The mouse works too: click to select, click again to fold, wheel to scroll.
`Ctrl+T` opens Tachikoma's theme picker.

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
- **Types and modules** are treated as leaves — their internals are deep, cyclic
  and almost never what you opened the explorer for.

Search only looks at rows that are on screen: matching against unloaded children
would mean walking the whole object graph, which is exactly what the laziness is
there to avoid.

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

`y` copies the one under the cursor to the clipboard.

## Reference

See the [Reference](@ref reference) page for the full API.
