"""
    Narcissus

A terminal UI for looking at Julia objects: point it at a value and walk its
fields, elements and entries, one level at a time.

```julia
using Narcissus
narcissus(my_object)
```

Built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl).
"""
module Narcissus

using PrecompileTools: @compile_workload
using AbstractTrees
using Tachikoma

# Pulls Tachikoma's callback generics into this module — `view`, `update!`,
# `should_quit`, `init!`, `cleanup!` and friends — so the methods below extend
# them rather than shadowing them with unrelated local functions the app loop
# would never call.
@tachikoma_app

export narcissus, @narcissus
export print_object, print_diff
export Component, ExplorationMode, Semantic, Fields
export Diff, Absent, diff_status

# `components`, `component_count`, `has_semantic_view` and `is_leaf` are
# deliberately NOT exported: they are the names every tree, graph and container
# package reaches for, and colliding with one of those in the REPL is a worse
# outcome than typing the module name. Extend them qualified:
#
#     Narcissus.components(::Narcissus.Semantic, x::MyType) = ...

include("components.jl")
include("inspect.jl")
include("compare.jl")
include("nodes.jl")
include("format.jl")
include("tree_widget.jl")
include("explorer.jl")
include("print.jl")
include("precompile.jl")

end
