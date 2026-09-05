```@meta
CurrentModule = Narcissus
```

# [The decomposition interface](@id interface)

Narcissus walks an object by asking it, repeatedly, "what are you made of?".
Four functions answer that question, and all four are yours to overload:

| Function                    | Answers                                            |
|:----------------------------|:---------------------------------------------------|
| [`components`](@ref)        | what are the parts?                                |
| [`component_count`](@ref)   | how many parts, without building any?              |
| [`has_semantic_view`](@ref) | do you decompose differently in the two modes?     |
| [`is_leaf`](@ref)           | should the explorer refuse to go inside you?       |

You need a method for a type only when the default is wrong. The default reads
struct fields, which is right for most things.

## The two modes

Every node carries an [`ExplorationMode`](@ref), and `m` flips it:

- [`Semantic`](@ref) — what the value **means**. A `Dict` is its entries, a
  `Vector` is its elements, a `Set` is its members.
- [`Fields`](@ref) — what the value **is**. A `Dict` is `slots`, `keys`,
  `vals`, `ndel`, `count`, `age`, `idxfloor`, `maxprobe`; a `Vector` is `ref`
  and `size`.

```text
▾ d::Dict{Symbol, Int64} = Dict(:a=>1, :b=>2)      ▾ d::Dict{Symbol, Int64} ·fields = …
├─ :a::Int64 = 1                                   ├─▸slots::Memory{UInt8} = UInt8[0xb5, …
└─ :b::Int64 = 2                                   ├─▸keys::Memory{Symbol} = [:a, :b, #un…
                                                   ├─▸vals::Memory{Int64} = [1, 2, 140644…
       semantic                                    ├─ ndel::Int64 = 0
                                                   ├─ count::Int64 = 2
                                                   └─ …          fields
```

`components(::Fields, x)` is generic and reads the fields Julia stores, so you
almost never write one. `components(::Semantic, x)` falls back to the field
view, which is why a plain struct looks identical in both modes — only types
with something better to say need a method.

The mode propagates: children opened under a field-mode node inherit it, so
dropping into `fields` means you meant to spelunk the storage *below* a value
and not merely at it.

## Types and modules

Two built-in views exist because the same question — "what are you made of?" —
has a good answer for things that are not values:

A **type** decomposes into its fields' *types*, which turns
`narcissus(SomeType)` into a readable map of an unfamiliar package:

```text
Run::type = Run
├─ name::type = String
├─ cfg::type = Cfg
│  ├─ lr::type = Float64
│  └─ tags::type = Vector{Symbol}
└─ losses::type = Vector{Float64}
```

Anything without a definite layout — an abstract type, a `UnionAll`, a `Union`
— has nothing to show and is a leaf. Paths are `fieldtype(fieldtype(T, :cfg), :lr)`,
which evaluates.

A **function** decomposes into its methods, keyed by their argument signatures:

```text
▾ components::function = components (generic function with 13 methods)
├─ (::Semantic, ::Module)::Method = components(::Semantic, m::Module) @ Narcissus …
├─ (::Semantic, ::Diff)::Method   = components(::Semantic, d::Diff) @ Narcissus …
└─ (::Semantic, ::Any)::Method    = components(::Semantic, x) @ Narcissus …
```

Its *field* view is what the closure captured — usually nothing, and
interesting exactly when it is not. The detail pane shows the function's
docstring, reached through its binding rather than its value, because that is
where Julia files documentation. Types and modules get theirs the same way.

A **module** is the one place the two modes map onto something people already
have names for:

| Mode       | A module is…                                          |
|:-----------|:-------------------------------------------------------|
| `Semantic` | what it offers — `names(m)`, the public API            |
| `Fields`   | everything it defines — internals, imports, the lot    |

So `narcissus(SomePackage)` is a browsable API listing, and `m` drops you into
the internals. Because a package's names are a jumble of four different kinds
of thing, `f` narrows the listing to one at a time — functions, then types,
then modules, then plain values — using [`binding_kind`](@ref). The module's own name is filtered out (every module exports
itself, and a row leading back to where you already are is noise), and the
binding lists are memoised — press `r` on a module node after defining
something new to re-read it.

## A worked example

A ring buffer stores more than it holds. Its fields are honest but useless:
you want to see the three live elements, not a five-element backing array and
an integer.

```julia
using Narcissus

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

Three methods, and the type now behaves like a first-class container: it
elides when long, compares against another ring buffer, and flips back to
`store`/`len` with `m`.

## What goes in a `Component`

A row is built out of exactly four things.

```
├─▸ weights::Matrix{Float64} = [0.1 0.2; 0.3 0.4]
    └ key    └ from `value`    └ from `value`
```

### `key` — the label in the left column

Short, and specific enough to tell siblings apart. Following the built-in
conventions keeps a custom type from looking foreign next to a `Vector`:

| Container      | `key`                                                 |
|:---------------|:------------------------------------------------------|
| struct field   | the bare name, `"weights"`                            |
| sequence       | `"[3]"`, or `"[2, 5]"` for a multidimensional index   |
| dictionary     | the key as Julia code — `repr(k)`, so `":name"`       |

The key shares a row with the type and the value, so keep it to a few
characters where you can. It is also what `/` searches, along with the type and
the rendered value.

### `template` — the path expression

The Julia expression that reaches this component from its parent, with `{}`
standing in for the parent's own path:

| Template               | Path it produces          |
|:-----------------------|:--------------------------|
| `"{}.weights"`         | `model.layers[2].weights` |
| `"{}[3]"`              | `v[3]`                    |
| `"{}[:name]"`          | `d[:name]`                |
| `"collect({})[2]"`     | `collect(s)[2]`           |
| `"{}"`                 | the parent's own path     |

Paths compose as the tree descends, and the result is what `y` copies to the
clipboard — so make it something that can be pasted into the REPL and
evaluated. When no expression reaches the component, use `"{}"`: naming the
parent is honest, inventing an accessor that does not work is not.

### `value` — the thing itself

Whatever the component holds. Two stand-ins exist for the awkward cases, and
reaching for them is much better than throwing:

- [`Undef`](@ref) — a field that is declared but never assigned.
- [`AccessError`](@ref) — a value that could not be retrieved.

### `kind` — how the key is coloured

`:field`, `:index` or `:key`. Purely cosmetic: it tells the reader at a glance
whether they are looking at a struct, a sequence or a mapping.

## The contract

`components` must be:

- **Iterable, not necessarily indexable.** The explorer only ever takes a
  window out of the result — `Iterators.drop` then `Iterators.take` — so a lazy
  generator is the right shape and keeps a million-element container cheap.
- **Stably ordered.** Iteration order is display order, and it must not change
  between calls for an unchanged value. Windowing, the `…` batch loader and
  "re-read this node" all assume component *n* is the same component next time.
- **In agreement with `component_count`.** The count decides whether a row gets
  an expansion arrow and where the elision marker goes. A count that disagrees
  with the iterator produces a phantom `… N more` row.
- **Cheap to build.** It is called every time a node is opened, and again for
  each further batch of a long container.
- **Non-throwing.** Wrap a failing lookup in `AccessError` so it becomes one
  visible row. If the method itself throws, the explorer catches it and shows a
  single error row rather than dying — but you lose the other components.

## Opting out entirely

[`is_leaf`](@ref) stops the explorer at a value in *both* modes:

```julia
Narcissus.is_leaf(::MyOpaqueHandle) = true
```

`Type`, `Symbol`, `AbstractString` and `AbstractChar` are leaves out of the box.

## Trait-based views

Some ecosystems decide what a value *is* by trait rather than by type, and
there is no method signature that captures them —
`Tables.istable(typeof(x))` is true for a `DataFrame` without `DataFrame`
sharing any abstract supertype you could dispatch on.

[`register_semantic!`](@ref) takes the three functions instead:

```julia
function __init__()
    Narcissus.register_semantic!(
        x -> Tables.istable(typeof(x)),                       # applies
        x -> length(Tables.columnnames(Tables.columns(x))),   # count
        x -> (Component(String(n), "Tables.getcolumn({}, :\$n)",
                        Tables.getcolumn(Tables.columns(x), n))
              for n in Tables.columnnames(Tables.columns(x))),
    )
end
```

Registrations are consulted only for values that no `components` method already
claims, so they never shadow ordinary dispatch — and a registered view answers
[`has_semantic_view`](@ref) `true` without needing a method of its own.

## Packages that already have a view

Two extensions ship with Narcissus and load themselves as soon as the package
they are about is in the session — nothing to import, nothing to call.

[**Dictionaries.jl**](https://github.com/andyferris/Dictionaries.jl). An
`AbstractDictionary` is deliberately not an `AbstractDict`, so without a view
of its own a `Dictionary` opens as `indices` and `values` — two parallel
vectors you have to line up by eye. It decomposes into entries instead, keyed
exactly as a `Dict`'s are, and an `AbstractIndices` — whose members *are* its
keys — decomposes into its members the way a `Set` does:

```text
▾ d::Dictionary{Symbol, Int64} = {:a │ 1, :b │ 2}     ▾ d::Dictionary{…} ·fields = …
├─ :a::Int64 = 1        @ d[:a]                        ├─▸indices::Indices{Symbol} = {:a, :b}
└─ :b::Int64 = 2        @ d[:b]                        └─▸values::Vector{Int64} = [1, 2]

           semantic                                                  fields
```

[**Tables.jl**](https://github.com/JuliaData/Tables.jl). Anything satisfying
`Tables.istable` — a `DataFrame`, a `CSV.File`, a `TypedTable` — decomposes
into its columns, each of which you can then walk like any other vector:

```text
▾ df::DataFrame = 3×2 DataFrame …
├─▸name::Vector{String}   = ["ada", "bob", "cy"]   @ Tables.getcolumn(df, :name)
└─▸score::Vector{Float64} = [0.9, 0.7, 0.4]        @ Tables.getcolumn(df, :score)
```

The column count comes from `Tables.schema` where the table has one, so opening
a node never materialises a lazy table just to find out how wide it is. Values
that already have a better view keep it: a `NamedTuple` of vectors is a column
table, but its fields are those columns under those names and `df.name` is a
nicer path than `Tables.getcolumn(df, :name)`, so it stays a struct; a
`Vector` of `NamedTuple`s stays an array of rows.

## Comparison comes along for free

`narcissus(x, y)` wraps the pair in a [`Diff`](@ref), which is itself a value
that implements this interface — it decomposes by zipping the components of
both sides together. A type that defines `components(::Semantic, …)` therefore
compares element by element with no further work:

```text
~ rb ⇄ rb2::RingBuffer = RingBuffer([1.0, 2.0, …  →  RingBuffer([1.0, 9.0, …
├─ · [1]::Float64 = 1.0
├─ ~ [2]::Float64 = 2.0 → 9.0
└─ + [3]::Float64 = 3.0
```

Positional pairing is the default. Dictionaries and sets pair by key and by
membership instead, so a reordered `Dict` does not read as entirely changed.

## Structural equality

Deciding whether a row is `:same` cannot just call `isequal`: for a
`mutable struct`, `==` falls back to `===`, and two field-by-field identical
objects compare unequal. [`same_value`](@ref) uses `isequal` where it is
meaningful and walks components where it is not — see
[`trustworthy_equality`](@ref) for how that call is made, and
[`EQUALITY_BUDGET`](@ref) for the bound that keeps a pathological object from
hanging the explorer.

## Reference

Full docstrings for all of the above live on the [Reference](@ref reference)
page: [`components`](@ref), [`component_count`](@ref),
[`has_semantic_view`](@ref), [`is_leaf`](@ref), [`Component`](@ref),
[`ExplorationMode`](@ref), [`Undef`](@ref), [`AccessError`](@ref),
[`register_semantic!`](@ref), [`module_names`](@ref),
[`binding_kind`](@ref), [`docstring`](@ref).
