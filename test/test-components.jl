@testsnippet Fixtures begin
    using Narcissus: components, component_count, component_window, n_components,
                     expandable, is_leaf, has_semantic_view, Undef, AccessError,
                     Component, Semantic, Fields

    struct Leaf
        α::Float64
        label::String
    end

    struct Branch
        id::Int
        leaf::Leaf
        data::Matrix{Float64}
        tags::Dict{Symbol,Int}
    end

    struct PartlyInit
        a::Int
        b::Any
        PartlyInit(a) = new(a)
    end

    struct OddName
        var"a b"::Int
        ok::Int
    end

    struct Grumpy end
    Base.show(io::IO, ::Grumpy) = error("this show method always throws")

    struct BadVector <: AbstractVector{Int} end
    Base.size(::BadVector) = (2,)
    Base.getindex(::BadVector, i::Int) = error("no element $i")

    mutable struct Loop
        name::String
        me::Any
        Loop(name) = (l = new(name); l.me = l; l)
    end

    sample_branch() = Branch(7, Leaf(0.5, "hi"), [1.0 2.0; 3.0 4.0],
                             Dict(:a => 1, :b => 2))

    "The semantic window, which is what most of these tests care about."
    window(x, start, limit) = component_window(Semantic(), x, start, limit)

    struct RingBuffer
        store::Vector{Float64}
        len::Int
    end
    Narcissus.has_semantic_view(::RingBuffer) = true
    Narcissus.component_count(::Semantic, r::RingBuffer) = r.len
    Narcissus.components(::Semantic, r::RingBuffer) =
        (Component("[$i]", "{}.store[$i]", r.store[i]) for i in 1:r.len)
end

@testitem "struct fields become components" tags=[:unit] setup=[Fixtures] begin
    b = sample_branch()
    kids = window(b, 1, 10)
    @test [k.key for k in kids] == ["id", "leaf", "data", "tags"]
    @test all(k -> k.kind === :field, kids)
    @test kids[1].value == 7
    @test kids[2].template == "{}.leaf"
    @test n_components(Semantic(), b) == 4
    @test expandable(Semantic(), b)
end

@testitem "array children carry cartesian paths" tags=[:unit] setup=[Fixtures] begin
    kids = window([1.0 2.0; 3.0 4.0], 1, 10)
    @test [k.key for k in kids] == ["[1, 1]", "[2, 1]", "[1, 2]", "[2, 2]"]
    @test kids[3].template == "{}[1, 2]"
    @test kids[3].value == 2.0

    vec_kids = window([10, 20, 30], 1, 10)
    @test [k.template for k in vec_kids] == ["{}[1]", "{}[2]", "{}[3]"]
end

@testitem "dicts, sets and tuples decompose" tags=[:unit] setup=[Fixtures] begin
    d = window(Dict(:a => 1), 1, 10)
    @test d[1].key == ":a"
    @test d[1].template == "{}[:a]"
    @test d[1].kind === :key

    s = window(Set([42]), 1, 10)
    @test s[1].template == "collect({})[1]"
    @test s[1].value == 42

    t = window((1, "two"), 1, 10)
    @test [k.key for k in t] == ["[1]", "[2]"]

    nt = window((x = 1, y = 2), 1, 10)
    @test [k.key for k in nt] == ["x", "y"]
    @test nt[1].kind === :field
end

@testitem "slicing takes a window" tags=[:unit] setup=[Fixtures] begin
    v = collect(1:1000)
    @test length(window(v, 1, 5)) == 5
    @test [k.value for k in window(v, 996, 10)] == 996:1000
    @test isempty(window(v, 1, 0))
end

@testitem "atomic values never decompose" tags=[:unit] setup=[Fixtures] begin
    for v in (1, 1.5, "text", :sym, 'c', nothing, missing, Int, Base)
        @test !expandable(Semantic(), v)
        @test isempty(window(v, 1, 10))
    end
    @test is_leaf(SubString("abcdef", 2, 4))   # has fields, still atomic
end

@testitem "undefined fields and bad access are values" tags=[:unit] setup=[Fixtures] begin
    kids = window(PartlyInit(1), 1, 10)
    @test kids[1].value == 1
    @test kids[2].value isa Undef

    bad = window(BadVector(), 1, 10)
    @test length(bad) == 2
    @test all(k -> k.value isa AccessError, bad)
end

@testitem "odd field names get a getfield path" tags=[:unit] setup=[Fixtures] begin
    kids = window(OddName(1, 2), 1, 10)
    @test kids[1].template == "getfield({}, Symbol(\"a b\"))"
    @test kids[2].template == "{}.ok"
end

@testitem "field mode reads what Julia stores" tags=[:unit] setup=[Fixtures] begin
    fields(x) = component_window(Fields(), x, 1, 20)

    d = fields(Dict(:a => 1))
    @test [k.key for k in d] ==
          ["slots", "keys", "vals", "ndel", "count", "age", "idxfloor", "maxprobe"]
    @test all(k -> k.kind === :field, d)
    @test d[1].template == "{}.slots"

    v = fields([1.0, 2.0])
    @test [k.key for k in v] == ["ref", "size"]
    @test v[2].value == (2,)

    # A plain struct looks the same in both modes.
    @test [k.key for k in fields(sample_branch())] ==
          [k.key for k in window(sample_branch(), 1, 20)]
end

@testitem "has_semantic_view marks the dual-view types" tags=[:unit] setup=[Fixtures] begin
    @test has_semantic_view(Dict(:a => 1))
    @test has_semantic_view([1, 2])
    @test has_semantic_view(Set([1]))
    @test !has_semantic_view((1, 2))          # a tuple's fields are its elements
    @test !has_semantic_view((x = 1,))
    @test !has_semantic_view(sample_branch())
    @test !has_semantic_view("text")
end

@testitem "a type can define its own semantic view" tags=[:unit] setup=[Fixtures] begin
    r = RingBuffer([1.0, 2.0, 3.0, 0.0, 0.0], 3)

    @test has_semantic_view(r)
    @test n_components(Semantic(), r) == 3
    sem = component_window(Semantic(), r, 1, 10)
    @test [k.key for k in sem] == ["[1]", "[2]", "[3]"]
    @test [k.value for k in sem] == [1.0, 2.0, 3.0]
    @test sem[2].template == "{}.store[2]"

    # Field mode is generic and still sees the storage.
    fld = component_window(Fields(), r, 1, 10)
    @test [k.key for k in fld] == ["store", "len"]

    # Windowing works on a custom (lazy) generator too.
    @test [k.key for k in component_window(Semantic(), r, 2, 1)] == ["[2]"]
end

@testitem "a throwing components method is contained" tags=[:unit] setup=[Fixtures] begin
    struct Hostile end
    Narcissus.has_semantic_view(::Hostile) = true
    Narcissus.component_count(::Semantic, ::Hostile) = 3
    Narcissus.components(::Semantic, ::Hostile) = error("not today")

    got = component_window(Semantic(), Hostile(), 1, 10)
    @test length(got) == 1
    @test got[1].value isa AccessError
end
