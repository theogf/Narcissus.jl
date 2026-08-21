@testitem "the tree is built lazily" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, load_children!, toggle!, expand_recursive!

    root = root_node(sample_branch(), "b")
    @test !root.loaded
    @test length(flatten(root)) == 1     # collapsed: just the root row

    toggle!(root)
    @test root.loaded && root.expanded
    @test length(flatten(root)) == 5
    # Grandchildren are still untouched.
    @test all(c -> !c.loaded, root.children)
end

@testitem "paths compose down the tree" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, expand_recursive!

    root = root_node(sample_branch(), "b")
    expand_recursive!(root, 2)
    paths = [r.node.path for r in flatten(root)]
    @test "b.leaf.α" in paths
    @test "b.data[2, 1]" in paths
    @test "b.tags[:a]" in paths
end

@testitem "cycles are marked, not followed" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, expand_recursive!

    root = root_node(Loop("self"), "l")
    expand_recursive!(root, 4)
    rows = flatten(root)
    cycles = filter(r -> r.node.kind === :cycle, rows)
    @test length(cycles) == 1
    @test cycles[1].node.path == "l.me"
    @test !cycles[1].node.expandable
    @test length(rows) < 10          # did not recurse forever
end

@testitem "long containers elide and load on demand" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, toggle!, expand_elided!

    root = root_node(collect(1:1000), "v"; limit=10)
    toggle!(root)
    rows = flatten(root)
    @test length(rows) == 12                     # root + 10 elements + elision
    elided = rows[end].node
    @test elided.kind === :elided
    @test elided.next_start == 11

    expand_elided!(elided)
    @test length(flatten(root)) == 22
    @test flatten(root)[12].node.value == 11
end

@testitem "collapse and recursive expand" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, expand_recursive!, collapse_recursive!

    root = root_node(sample_branch(), "b")
    expand_recursive!(root, 3)
    @test length(flatten(root)) > 10

    collapse_recursive!(root)
    @test length(flatten(root)) == 1
end

@testitem "previews survive broken show methods" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, node_text, preview, type_string

    n = root_node(Grumpy(), "g")
    @test occursin("show error", preview(n))
    @test endswith(type_string(n), "Grumpy")
    @test occursin("Grumpy", node_text(n))
end

@testitem "detail pane describes a value" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, detail_spans

    text = join(s.content for s in detail_spans(root_node([1.0, 2.0], "v"), 60))
    @test occursin("path", text)
    @test occursin("Vector{Float64}", text)
    @test occursin("array", text)
    @test occursin("(2,)", text)
    @test occursin("2-element", text)   # from the show(::MIME"text/plain") dump
end

@testitem "mode belongs to a node and its subtree" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, expand_recursive!, toggle_mode!, set_mode!,
                     Semantic, Fields, mode_name

    root = root_node(Dict(:a => [1.0, 2.0]), "d")
    expand_recursive!(root, 1)
    @test [r.node.key for r in flatten(root)][2] == ":a"

    @test toggle_mode!(root)
    @test root.mode isa Fields
    expand_recursive!(root, 1)
    keys_shown = [r.node.key for r in flatten(root)]
    @test "slots" in keys_shown
    @test ":a" ∉ keys_shown

    # Children opened under a field-mode node inherit it.
    slots = first(c for c in root.children if c.key == "slots")
    @test slots.mode isa Fields
    @test flatten(root)[2].node.path == "d.slots"

    @test toggle_mode!(root)
    @test root.mode isa Semantic
    expand_recursive!(root, 1)
    @test [r.node.key for r in flatten(root)][2] == ":a"
end

@testitem "values with one view refuse to toggle" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, toggle_mode!, set_mode!, Fields

    @test !toggle_mode!(root_node(sample_branch(), "b"))
    @test !toggle_mode!(root_node((1, 2), "t"))
    @test !toggle_mode!(root_node("text", "s"))

    # set_mode! is the unconditional form.
    n = root_node(sample_branch(), "b")
    @test set_mode!(n, Fields())
    @test !set_mode!(n, Fields())      # already there
end

@testitem "a root can start in field mode" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, flatten, expand_recursive!, Fields, exploration_mode

    root = root_node([1.0, 2.0], "v"; mode=Fields())
    expand_recursive!(root, 0)
    # Julia's own answer, so this holds whether or not Array exposes fields.
    @test [r.node.key for r in flatten(root)] ==
          ["v"; [String(n) for n in fieldnames(Vector{Float64})]]

    @test exploration_mode(:fields) isa Fields
    @test_throws ArgumentError exploration_mode(:nonsense)
end

@testitem "anomalies are found and cached" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, node_anomaly, anomaly, flatten, expand_recursive!

    @test anomaly(NaN) === :nan
    @test anomaly(Inf) === :inf
    @test anomaly([1.0, NaN]) === :nan
    @test anomaly(Int[]) === :empty
    @test anomaly(missing) === :missing
    @test anomaly(1.0) === nothing
    @test anomaly([1.0, 2.0]) === nothing
    @test anomaly(["a"]) === nothing        # not worth scanning
    @test anomaly(nothing) === nothing      # too ordinary to flag

    n = root_node([1.0, NaN], "v")
    @test node_anomaly(n) === :nan
    @test node_anomaly(n) === :nan          # cached, same answer
    @test node_anomaly(root_node(1.0, "x")) === nothing
end

@testitem "a deep walk finds what is not loaded" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, find_node, reveal!, flatten, SEARCH_BUDGET

    root = root_node(sample_branch(), "b")
    @test length(flatten(root)) == 1                  # nothing loaded yet

    found = find_node(root, n -> n.key == "label")
    @test found !== nothing
    @test found.path == "b.leaf.label"

    # It was found but is not yet on screen; revealing opens its ancestors.
    @test length(flatten(root)) == 1
    reveal!(found)
    @test found.path in [r.node.path for r in flatten(root)]

    @test find_node(root, n -> n.key == "nonexistent") === nothing

    # The budget is a hard stop, not a suggestion.
    budget = Ref(3)
    @test find_node(root, n -> n.key == "label"; budget) === nothing
    @test budget[] < 0
end

@testitem "memory sizes are computed once" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: root_node, node_bytes, human_bytes, byte_size, load_children!

    n = root_node(sample_branch(), "b")
    total = node_bytes(n)
    @test total > 0
    @test node_bytes(n) == total          # cached

    load_children!(n)
    data = only(c for c in n.children if c.key == "data")
    @test 0 < node_bytes(data) <= total

    @test human_bytes(12) == "12 B"
    @test human_bytes(4096) == "4.0 KiB"
    @test occursin("MiB", human_bytes(1_500_000))
    @test byte_size(nothing) >= 0
end

@testitem "size measurement is bounded and refuses machinery" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: bounded_size, byte_size, skip_for_size, SIZE_BUDGET

    # `Base.summarysize` of a single Method is ~111 MB: it reaches the module,
    # the specializations, and from there most of the runtime. Measuring a
    # method list would do that once per row.
    for machinery in (Base, Vector{Float64}, first(methods(sin)), methods(+))
        bytes, capped = bounded_size(machinery)
        @test bytes < 1024
        @test !capped
    end
    @test skip_for_size(Base)
    @test skip_for_size(Int)
    @test skip_for_size(first(methods(sin)))
    @test !skip_for_size([1, 2, 3])

    # Ordinary data is measured, and close to what summarysize would say.
    data = rand(1000)
    @test 0.9 < byte_size(data) / Base.summarysize(data) < 1.1
    @test byte_size("hello") == Base.summarysize("hello")

    # Shared children are counted once, and a cycle terminates.
    shared = rand(500)
    @test byte_size([shared, shared]) < 1.5 * byte_size([shared])
    loop = Any[]
    push!(loop, loop)
    @test byte_size(loop) > 0

    # The budget is a hard stop, and the result says it is a lower bound.
    _, capped = bounded_size([rand(3) for _ in 1:50_000]; budget=500)
    @test capped
end
