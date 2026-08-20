# Narcissus

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://theogf.github.io/Narcissus.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://theogf.github.io/Narcissus.jl/dev)
[![Test workflow status](https://github.com/theogf/Narcissus.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/theogf/Narcissus.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/theogf/Narcissus.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/theogf/Narcissus.jl)
[![Docs workflow Status](https://github.com/theogf/Narcissus.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/theogf/Narcissus.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

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

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/theogf/Narcissus.jl")
```

## Usage

`narcissus(obj)` opens the explorer and returns the value under the cursor when
you quit — so you can dig down to something interesting and keep it:

```julia
julia> layer = narcissus(model; name="model")   # navigate, then press q
julia> layer.weights
```

Keyword arguments:

| Argument | Default  | Meaning                                                          |
|:---------|:---------|:-----------------------------------------------------------------|
| `name`   | `"obj"`  | Label of the root, and the prefix of every path expression       |
| `expand` | `1`      | How many levels to open up front                                 |
| `limit`  | `100`    | Container elements pulled in per batch                           |

Anything else is forwarded to `Tachikoma.app`.

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

## What it does with awkward objects

An object explorer meets a lot of values that do not want to be explored, so
the traversal is deliberately defensive:

- **Lazy.** Children are read only when a node is opened. Pointing Narcissus at
  a large graph costs nothing until you walk into it.
- **Cycles** are detected by identity against the current path and marked
  `↺ already shown above` rather than followed.
- **Long containers** arrive `limit` at a time, with a `…` row at the end that
  pulls in the next batch when you open it.
- **Undefined fields** show as `#undef`; **`getindex`/`getfield` errors** and
  **throwing `show` methods** become visible markers, not stack traces.
- **Types and modules** are treated as leaves — their internals are deep, cyclic
  and never what you opened the explorer for.

Paths are real Julia expressions: `run.config.tags[2]`, `d[:key]`,
`getfield(x, Symbol("odd name"))`, `collect(s)[3]` for sets. `y` copies the one
under the cursor straight to the clipboard.
