@testsnippet DiffFixtures begin
    using Narcissus: Diff, Absent, diff_status, comparable, same_value,
                     trustworthy_equality, component_window, n_components,
                     root_node, flatten, node_status, expand_differences!,
                     expand_recursive!, node_text, Semantic, Fields

    struct Cfg
        lr::Float64
        tags::Vector{Symbol}
    end

    mutable struct Run2
        name::String
        cfg::Cfg
    end

    sides(d, mode=Semantic()) = component_window(mode, d, 1, 20)
    statuses(root) = [node_status(r.node) for r in flatten(root)]
end

@testitem "diff_status names what happened" tags=[:unit] setup=[DiffFixtures] begin
    @test diff_status(Diff(1, 1)) === :same
    @test diff_status(Diff(1, 2)) === :changed
    @test diff_status(Diff(Absent(), 2)) === :added
    @test diff_status(Diff(1, Absent())) === :removed
    @test diff_status(Diff(1, "one")) === :type
    @test diff_status(Diff([1, 2], [1, 2])) === :same
end

@testitem "equality sees through mutable structs" tags=[:unit] setup=[DiffFixtures] begin
    r = Run2("a", Cfg(0.1, [:x]))

    # `isequal` says these differ; they plainly do not.
    @test !isequal(r, deepcopy(r))
    @test same_value(Semantic(), r, deepcopy(r))
    @test diff_status(Diff(r, deepcopy(r))) === :same

    @test !same_value(Semantic(), r, Run2("b", Cfg(0.1, [:x])))
    @test same_value(Semantic(), [r], [deepcopy(r)])
    @test same_value(Semantic(), Dict(:k => r), Dict(:k => deepcopy(r)))
    @test !same_value(Semantic(), Dict(:k => r), Dict(:other => r))

    # Types that define their own equality are taken at their word.
    @test trustworthy_equality(Float64)
    @test trustworthy_equality(Vector{Float64})
    @test trustworthy_equality(Dict{Symbol,Int})
    @test !trustworthy_equality(Run2)
    @test !trustworthy_equality(Vector{Run2})   # `==` on a Vector defers to Run2
end

@testitem "equality is bounded, not unbounded" tags=[:unit] setup=[DiffFixtures] begin
    mutable struct Ouroboros
        me::Any
        Ouroboros() = (o = new(); o.me = o; o)
    end
    # Two distinct self-referential objects: the walk must stop, not hang.
    @test !same_value(Semantic(), Ouroboros(), Ouroboros())
end

@testitem "a comparison zips both sides" tags=[:unit] setup=[DiffFixtures] begin
    kids = sides(Diff(Cfg(0.1, [:x]), Cfg(0.2, [:x])))
    @test [k.key for k in kids] == ["lr", "tags"]
    @test kids[1].value == Diff(0.1, 0.2)
    @test kids[1].template == "{}.lr"

    # The longer side wins, and the tail is `Absent` on the short one.
    tail = sides(Diff([1, 2], [1, 2, 3]))
    @test length(tail) == 3
    @test tail[3].value.x isa Absent
    @test tail[3].value.y == 3
    @test diff_status(tail[3].value) === :added
end

@testitem "dictionaries pair by key" tags=[:unit] setup=[DiffFixtures] begin
    kids = sides(Diff(Dict(:a => 1, :b => 2), Dict(:b => 2, :c => 3)))
    by_key = Dict(k.key => k.value for k in kids)
    @test sort(collect(keys(by_key))) == [":a", ":b", ":c"]
    @test diff_status(by_key[":a"]) === :removed
    @test diff_status(by_key[":b"]) === :same
    @test diff_status(by_key[":c"]) === :added
    @test n_components(Semantic(), Diff(Dict(:a => 1), Dict(:b => 1))) == 2
end

@testitem "sets pair by membership" tags=[:unit] setup=[DiffFixtures] begin
    kids = sides(Diff(Set([1, 2]), Set([2, 3])))
    @test length(kids) == 3
    @test sort([diff_status(k.value) for k in kids]) == [:added, :removed, :same]
end

@testitem "unrelated types stop the comparison" tags=[:unit] setup=[DiffFixtures] begin
    @test !comparable(1, "one")
    @test comparable(Cfg(0.1, [:x]), Cfg(0.2, [:y]))     # same type
    @test comparable([1], [1.0])                          # parameters may differ

    root = root_node(Diff(1, "one"), "v")
    @test !root.expandable                                # nothing to line up
    @test node_status(root) === :type
end

@testitem "differing branches open, same ones fold" tags=[:unit] setup=[DiffFixtures] begin
    a = Run2("exp", Cfg(0.1, [:x, :y]))
    b = Run2("exp", Cfg(0.2, [:x, :y]))

    root = root_node(Diff(a, b), "a")
    expand_differences!(root, 8)
    shown = [(r.node.key, node_status(r.node)) for r in flatten(root)]
    @test ("name", :same) in shown
    @test ("lr", :changed) in shown
    @test ("tags", :same) in shown
    # `tags` matched, so its elements were never even looked at.
    @test !first(r.node for r in flatten(root) if r.node.key == "tags").expanded

    # Identical objects collapse to a single row.
    same = root_node(Diff(a, deepcopy(a)), "a")
    expand_differences!(same, 8)
    @test length(flatten(same)) == 1
end

@testitem "a comparison is lazy and cycle-safe" tags=[:unit] setup=[DiffFixtures] begin
    mutable struct Chain
        next::Any
        Chain() = (c = new(); c.next = c; c)
    end
    root = root_node(Diff(Chain(), Chain()), "c")
    expand_recursive!(root, 6)
    rows = flatten(root)
    @test any(r -> r.node.kind === :cycle, rows)
    @test length(rows) < 12
end

@testitem "comparisons honour the mode toggle" tags=[:unit] setup=[DiffFixtures] begin
    using Narcissus: toggle_mode!, has_semantic_view

    # A Dict, not a Vector: an Array exposes no fields before Julia 1.11, and
    # this is a test about the two modes rather than about Array's layout.
    stored = [String(n) for n in fieldnames(Dict{Symbol,Int})]

    d = Diff(Dict(:a => 1), Dict(:a => 2))
    @test has_semantic_view(d)
    @test [k.key for k in sides(d, Semantic())] == [":a"]
    @test [k.key for k in sides(d, Fields())] == stored

    root = root_node(d, "v")
    @test toggle_mode!(root)
    expand_recursive!(root, 0)
    @test [r.node.key for r in flatten(root)] == ["v"; stored]
    @test flatten(root)[2].node.path == "v.slots"
end

@testitem "diff rows show both sides" tags=[:unit] setup=[DiffFixtures] begin
    root = root_node(Diff(Cfg(0.1, [:x]), Cfg(0.2, [:x])), "c")
    expand_differences!(root, 4)
    lr = first(r.node for r in flatten(root) if r.node.key == "lr")
    @test occursin("0.1", node_text(lr))
    @test occursin("0.2", node_text(lr))
    @test occursin("→", node_text(lr))

    # An identical row prints the value once, not twice.
    tags = first(r.node for r in flatten(root) if r.node.key == "tags")
    @test node_text(tags) == "tags::Vector{Symbol} = [:x]"
end
