@testsnippet Ext begin
    using Narcissus:
        component_window, n_components, has_semantic_view, Component, Semantic, Fields

    window(x, mode = Semantic()) = component_window(mode, x, 1, 20)
    keys_of(x, mode = Semantic()) = [c.key for c in window(x, mode)]
    templates_of(x, mode = Semantic()) = [c.template for c in window(x, mode)]
end

# ── Dictionaries.jl ──────────────────────────────────────────────────

@testitem "a Dictionary decomposes into entries" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries: Dictionary

    d = Dictionary([:a, :b], [1, 2])
    @test has_semantic_view(d)
    @test n_components(Semantic(), d) == 2

    cs = window(d)
    @test [c.key for c in cs] == [":a", ":b"]
    @test [c.template for c in cs] == ["{}[:a]", "{}[:b]"]
    @test [c.value for c in cs] == [1, 2]
    @test all(c.kind === :key for c in cs)

    # Keyed exactly as a `Dict`'s entries are, quoting and all.
    @test templates_of(Dictionary(["a b", "c"], [10, 20])) == ["{}[\"a b\"]", "{}[\"c\"]"]

    @test isempty(window(Dictionary(Symbol[], Int[])))
end

@testitem "a Dictionary still has a field view" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries: Dictionary

    d = Dictionary([:a], [1])
    @test keys_of(d, Fields()) == ["indices", "values"]
    @test templates_of(d, Fields()) == ["{}.indices", "{}.values"]
end

@testitem "Indices decompose into their members" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries: Indices

    i = Indices([:x, :y, :z])
    @test has_semantic_view(i)
    @test n_components(Semantic(), i) == 3

    cs = window(i)
    # The member is the key — `i[:x]` is `:x`, so an entry view would say it
    # twice — and the path that reaches it is positional, as a `Set`'s is.
    @test [c.key for c in cs] == [":x", ":y", ":z"]
    @test [c.template for c in cs] == ["collect({})[1]", "collect({})[2]", "collect({})[3]"]
    @test [c.value for c in cs] == [:x, :y, :z]
    @test all(c.kind === :key for c in cs)
end

@testitem "a dictionary window is a window" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries: Dictionary

    d = Dictionary(1:100, 101:200)
    @test n_components(Semantic(), d) == 100
    cs = component_window(Semantic(), d, 5, 3)
    @test [c.key for c in cs] == ["5", "6", "7"]
    @test [c.value for c in cs] == [105, 106, 107]
end

@testitem "dictionary paths evaluate" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries: Dictionary, Indices

    obj = Dictionary([:a], [1])
    @test eval(Meta.parse(replace(window(obj)[1].template, "{}" => "obj"))) == 1

    obj = Indices([:x, :y])
    @test eval(Meta.parse(replace(window(obj)[2].template, "{}" => "obj"))) === :y
end

# ── Tables.jl ────────────────────────────────────────────────────────

@testitem "a table decomposes into columns" tags=[:unit, :ext] setup=[Ext] begin
    using Tables

    t = Tables.table([1 2; 3 4])
    @test has_semantic_view(t)
    @test n_components(Semantic(), t) == 2

    cs = window(t)
    @test [c.key for c in cs] == ["Column1", "Column2"]
    @test [c.template for c in cs] ==
          ["Tables.getcolumn({}, :Column1)", "Tables.getcolumn({}, :Column2)"]
    @test [collect(c.value) for c in cs] == [[1, 3], [2, 4]]
    @test all(c.kind === :field for c in cs)

    # And the field view still shows the storage underneath.
    @test keys_of(t, Fields()) == ["names", "lookup", "matrix"]
end

@testitem "an odd column name still parses as a path" tags=[:unit, :ext] setup=[Ext] begin
    using Tables

    obj = Tables.table([1 2]; header = [Symbol("total (€)"), :n])
    c = window(obj)[1]
    @test c.key == "total (€)"
    @test c.template == "Tables.getcolumn({}, Symbol(\"total (€)\"))"
    @test eval(Meta.parse(replace(c.template, "{}" => "obj"))) == [1]
end

@testitem "the table view yields to a better one" tags=[:unit, :ext] setup=[Ext] begin
    using Tables

    # A `NamedTuple` of vectors is a column table, but its fields *are* those
    # columns and `{}.a` beats `Tables.getcolumn({}, :a)`.
    nt = (a = [1, 2], b = [3.0, 4.0])
    @test Tables.istable(nt)
    @test !has_semantic_view(nt)
    @test templates_of(nt) == ["{}.a", "{}.b"]

    # A vector of rows is a table too, and stays an array of them.
    rows = [(a = 1, b = 2), (a = 3, b = 4)]
    @test Tables.istable(rows)
    @test templates_of(rows) == ["{}[1]", "{}[2]"]
end

@testitem "the built-in views are left alone" tags=[:unit, :ext] setup=[Ext] begin
    using Dictionaries, Tables

    @test templates_of(Dict(:a => 1)) == ["{}[:a]"]
    @test templates_of(Set([42])) == ["collect({})[1]"]
    @test templates_of([1, 2]) == ["{}[1]", "{}[2]"]
    @test templates_of((x = 1, y = 2)) == ["{}.x", "{}.y"]
end
