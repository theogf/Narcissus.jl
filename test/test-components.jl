@testsnippet Fixtures begin
    using Narcissus:
        components,
        component_count,
        component_window,
        n_components,
        expandable,
        is_leaf,
        has_semantic_view,
        Undef,
        AccessError,
        Component,
        Semantic,
        Fields

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

    # Deep rather than wide: `show` walks all of it, and `:limit` does not
    # bound nesting the way it bounds a container.
    struct Chain
        head::Int
        tail::Any
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

    sample_branch() = Branch(7, Leaf(0.5, "hi"), [1.0 2.0; 3.0 4.0], Dict(:a => 1, :b => 2))

    "The semantic window, which is what most of these tests care about."
    window(x, start, limit) = component_window(Semantic(), x, start, limit)

    struct RingBuffer
        store::Vector{Float64}
        len::Int
    end
    Narcissus.has_semantic_view(::RingBuffer) = true
    Narcissus.component_count(::Semantic, r::RingBuffer) = r.len
    Narcissus.components(::Semantic, r::RingBuffer) =
        (Component("[$i]", "{}.store[$i]", r.store[i]) for i = 1:r.len)
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
    for v in (1, 1.5, "text", :sym, 'c', nothing, missing, Int)
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
    @test [k.key for k in d] == ["slots", "keys", "vals", "ndel", "count", "age", "idxfloor", "maxprobe"]
    @test all(k -> k.kind === :field, d)
    @test d[1].template == "{}.slots"

    # Whatever Julia stores an Array as — `ref`/`size` from 1.11, nothing at
    # all before that — the field view is exactly that and nothing else.
    v = fields([1.0, 2.0])
    @test [k.key for k in v] == [String(n) for n in fieldnames(Vector{Float64})]
    if :size in fieldnames(Vector{Float64})
        @test only(k for k in v if k.key == "size").value == (2,)
    end

    # A plain struct looks the same in both modes.
    @test [k.key for k in fields(sample_branch())] == [k.key for k in window(sample_branch(), 1, 20)]
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

@testitem "a type decomposes into its fields' types" tags=[:unit] setup=[Fixtures] begin
    kids = window(Branch, 1, 10)
    @test [k.key for k in kids] == ["id", "leaf", "data", "tags"]
    @test kids[2].value === Leaf                       # the field's *type*
    @test kids[2].template == "fieldtype({}, :leaf)"

    # A tuple type's fields are positional.
    @test [k.key for k in window(Tuple{Int,String}, 1, 10)] == ["[1]", "[2]"]

    # Nothing with an indefinite layout has anything to show.
    for T in (AbstractVector, Integer, Union{Int,String}, Int)
        @test n_components(Semantic(), T) == 0
    end
    @test !has_semantic_view(Branch)                   # one view, not two
end

@testitem "a module decomposes into its bindings" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: module_names, forget_modules!

    public = module_names(Narcissus)
    everything = module_names(Narcissus; all = true)
    @test :narcissus in public
    @test :Component in public
    @test length(everything) > length(public)
    @test :DEFAULT_LIMIT in everything                 # an internal
    @test :DEFAULT_LIMIT ∉ public
    # Deliberately not exported: too generic a name to put in anyone's Main.
    @test :components ∉ public
    @test :components in everything
    @test :is_leaf ∉ public
    @test :Narcissus ∉ public                          # never itself
    @test all(n -> !startswith(String(n), "#"), everything)

    # The two modes are the public API and the whole contents.
    @test has_semantic_view(Narcissus)
    @test n_components(Semantic(), Narcissus) == length(public)
    @test n_components(Fields(), Narcissus) == length(everything)

    kids = window(Narcissus, 1, 500)
    entry = only(k for k in kids if k.key == "narcissus")
    @test entry.value === Narcissus.narcissus
    @test entry.template == "{}.narcissus"

    # Operator-named bindings still get a usable path.
    ops = component_window(Fields(), Base, 1, 2000)
    bang = only(k for k in ops if k.key == "!=")
    @test bang.template == "getfield({}, Symbol(\"!=\"))"

    forget_modules!()
    @test module_names(Narcissus) == public
end

@testitem "a function decomposes into its methods" tags=[:unit] setup=[Fixtures] begin
    f(x::Int) = x
    f(x::String, y::Float64) = x
    f(x) = x

    @test has_semantic_view(f)
    @test n_components(Semantic(), f) == 3

    kids = window(f, 1, 10)
    @test all(k -> k.value isa Method, kids)
    @test any(k -> k.key == "(::Int64)", kids)
    @test any(k -> k.key == "(::String, ::Float64)", kids)
    @test all(k -> startswith(k.template, "collect(methods({}))["), kids)

    # The field view is what a closure captured — nothing, here.
    @test n_components(Fields(), f) == 0

    closure = let a = 41
        x -> x + a
    end
    @test n_components(Fields(), closure) == 1     # `a` was captured
end

@testitem "a scope decomposes into its variables" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: Locals, scope_or_module, has_semantic_view

    vars = Dict{Symbol,Any}(:model => [1.0, 2.0], :epochs => 5, Symbol("#self#") => sin)
    scope = Locals(vars)

    # Sorted and without the gensyms nobody wrote.
    @test scope.names == [:epochs, :model]
    @test length(scope) == 2
    @test !has_semantic_view(scope)              # these *are* the variables

    kids = window(scope, 1, 10)
    @test [k.key for k in kids] == ["epochs", "model"]
    @test all(k -> k.kind === :field, kids)
    # The path is the name as it is written in the scope, not a lookup into a
    # container that only exists in here.
    @test [k.template for k in kids] == ["epochs", "model"]
    @test kids[2].value == [1.0, 2.0]

    @test occursin("2 variables", sprint(show, scope))
    @test occursin("epochs::Int64", sprint(show, MIME"text/plain"(), scope))
end

@testitem "an empty scope falls back to the module" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: Locals, scope_or_module

    value, name = scope_or_module(Dict{Symbol,Any}(:x => 1), Main)
    @test value isa Locals
    @test name == "locals"

    # At the REPL prompt nothing is local; the globals are what was meant.
    value, name = scope_or_module(Dict{Symbol,Any}(), Base)
    @test value === Base
    @test name == "Base"
end

@testitem "module bindings sort into kinds" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: binding_kind, kind_label, BINDING_KINDS

    @test binding_kind(Base) === :module
    @test binding_kind(Int) === :type
    @test binding_kind(sin) === :function
    @test binding_kind(42) === :value
    @test BINDING_KINDS[1] === :all
    @test kind_label(:function) == "functions"
    @test kind_label(:value) == "values"
    @test kind_label(:all) == "all"

    # A macro is a function with an `@` in its name, and nothing else says so.
    @test binding_kind(getfield(Base, Symbol("@time"))) === :macro
    @test binding_kind(getfield(Narcissus, Symbol("@narcissus"))) === :macro
    @test !Narcissus.is_macro(sin)
    @test :macro in BINDING_KINDS
    @test kind_label(:macro) == "macros"
end

@testitem "documentation is found through the binding" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: docstring, doc_binding

    docs = docstring(Narcissus.components)
    @test docs !== nothing
    @test occursin("extension point", docs)

    @test docstring(Narcissus.Component) !== nothing
    @test docstring(Narcissus) !== nothing

    # A closure has no binding to file documentation under.
    a = 1
    @test doc_binding(x -> x + a) === nothing
    @test docstring(x -> x + a) === nothing
    @test doc_binding(42) === nothing
    @test docstring(42) === nothing
end

@testitem "a method is documented by its own signature" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: docstring, strip_ansi, has_method_doc, doc_signature

    "the function as a whole"
    function documented end
    "the one that takes an Int"
    documented(x::Int) = x
    documented(x::String) = x

    int_method = only(methods(documented, Tuple{Int}))
    str_method = only(methods(documented, Tuple{String}))

    @test doc_signature(int_method) === Tuple{Int}
    @test has_method_doc(int_method)
    @test occursin("takes an Int", strip_ansi(docstring(int_method; color = false)))

    # A method with nothing of its own falls back to the function's.
    @test !has_method_doc(str_method)
    @test occursin("as a whole", strip_ansi(docstring(str_method; color = false)))
end

@testitem "a type is documented by itself, not its constructors" tags=[:unit] setup=[
    Fixtures,
] begin
    using Narcissus: docstring, strip_ansi, has_own_doc

    "what a Widget is"
    struct Widget
        x::Int
    end
    "the two-argument constructor"
    Widget(x::Int, y::Int) = Widget(x + y)

    text = strip_ansi(docstring(Widget; color = false))
    @test occursin("what a Widget is", text)
    @test !occursin("two-argument", text)      # the constructors keep to themselves
    @test has_own_doc(Widget)

    # A type documented only through a constructor still shows that.
    struct Undocumented
        a::Int
    end
    "only the constructor is documented"
    Undocumented(a::Int, b::Int) = Undocumented(a + b)
    @test !has_own_doc(Undocumented)
    @test occursin(
        "only the constructor",
        strip_ansi(docstring(Undocumented; color = false)),
    )
end

@testitem "docstrings render as markdown" tags=[:unit] setup=[Fixtures] begin
    using Narcissus: docstring, strip_ansi

    coloured = docstring(Narcissus.components; width = 70)
    @test coloured !== nothing
    @test occursin('\e', coloured)                # formatting arrived as ANSI

    plain = strip_ansi(coloured)
    @test !occursin('\e', plain)
    @test !occursin("**", plain)                  # rendered, not raw markdown
    @test occursin("List the parts of", plain)
    @test occursin("•", plain)                    # a rendered bullet list

    # Prose is wrapped to the width asked for — code blocks are Julia's and
    # are left alone, so compare line counts rather than assert a hard bound.
    narrow = strip_ansi(docstring(Narcissus.components; width = 40))
    wide = strip_ansi(docstring(Narcissus.components; width = 100))
    @test count(==('\n'), narrow) > count(==('\n'), wide)
end
