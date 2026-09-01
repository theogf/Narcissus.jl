# ═══════════════════════════════════════════════════════════════════════
# Components ── the interface: how a value decomposes into named parts
# ═══════════════════════════════════════════════════════════════════════

"""
    ExplorationMode

How a value should be taken apart. Two modes ship with Narcissus:

- [`Semantic`](@ref) — what the value *means*: a `Dict`'s entries, an array's
  elements, a set's members.
- [`Fields`](@ref) — what the value *is*: the raw struct fields Julia stores,
  so a `Dict` becomes `slots`, `keys`, `vals`, `ndel`, … and a `Vector`
  becomes `ref` and `size`.

Every node in the explorer carries its own mode, toggled with `m`, and the
nodes opened underneath it inherit it.
"""
abstract type ExplorationMode end

"The meaning of a value: entries, elements, members. See [`ExplorationMode`](@ref)."
struct Semantic <: ExplorationMode end

"The storage of a value: its raw struct fields. See [`ExplorationMode`](@ref)."
struct Fields <: ExplorationMode end

mode_name(::Semantic) = "semantic"
mode_name(::Fields) = "fields"

"The other mode, for toggling."
other_mode(::Semantic) = Fields()
other_mode(::Fields) = Semantic()

"""
    exploration_mode(x) -> ExplorationMode

Coerce `:semantic` / `:fields` (or a mode instance) to an [`ExplorationMode`](@ref).
"""
exploration_mode(m::ExplorationMode) = m
function exploration_mode(s::Symbol)
    s === :semantic && return Semantic()
    s === :fields && return Fields()
    throw(ArgumentError("unknown exploration mode $(repr(s)); use :semantic or :fields"))
end

"""
    Undef

Placeholder for a struct field that is declared but not assigned
(`isdefined(x, i) === false`).
"""
struct Undef end

"""
    AccessError(err)

Placeholder for a component whose value could not be retrieved — `getindex` or
`getfield` threw. Keeps the exploration alive instead of taking the app down.
"""
struct AccessError
    err::Any
end

"""
    Component(key, template, value; kind=:index)

One part of a decomposed value, as returned by [`components`](@ref). A row in
the tree is built out of exactly these four things:

```
├─▸ weights::Matrix{Float64} = [0.1 0.2; 0.3 0.4]
    └ key    └ from `value`    └ from `value`
```

## `key` — the label in the left column

Short, and specific enough to tell siblings apart. The built-in conventions,
worth following so a custom type does not look foreign next to a `Vector`:

| Container      | `key`                      |
|:---------------|:---------------------------|
| struct field   | the bare name, `"weights"` |
| sequence       | `"[3]"`, or `"[2, 5]"` for a multidimensional index |
| dictionary     | the key as Julia code, `":name"` or `"\"host\""` — i.e. `repr(k)` |

It shares a row with the type and the value, so keep it to a few characters
where you can. It is also what `/` searches, along with the type and the
rendered value.

## `template` — the path expression

The Julia expression that reaches this component from its parent, with `{}`
standing in for the parent's own path: `"{}.weights"`, `"{}[3]"`,
`"{}[:name]"`, `"collect({})[2]"`. Paths compose as the tree descends, so a
component three levels down ends up as `model.layers[2].weights`, and that is
what `y` puts on the clipboard — make it something that can be pasted into the
REPL and evaluated.

When no expression reaches the component — a set member, say — use `"{}"`, so
the path names the parent rather than lying about the child.

## `value` — the thing itself

Whatever the component holds. Two stand-ins exist for the awkward cases, and
using them is much better than throwing:

- [`Undef`](@ref) for a field that is declared but not assigned.
- [`AccessError`](@ref) for a value that could not be retrieved.

## `kind` — how the key is coloured

`:field`, `:index` or `:key`. Purely cosmetic: it tells the reader at a glance
whether they are looking at a struct, a sequence or a mapping.
"""
struct Component
    key::String
    template::String
    value::Any
    kind::Symbol
end

Component(key::AbstractString, template::AbstractString, value; kind::Symbol = :index) =
    Component(String(key), String(template), value, kind)

# ═══════════════════════════════════════════════════════════════════════
# The interface
# ═══════════════════════════════════════════════════════════════════════

"""
    components(mode::ExplorationMode, x) -> iterable of Component

List the parts of `x`. **This is the extension point**: give your type a
`components(::Semantic, ::MyType)` method to control how the explorer walks it.

```julia
struct RingBuffer
    store::Vector{Float64}
    len::Int
end

Narcissus.has_semantic_view(::RingBuffer) = true
Narcissus.component_count(::Narcissus.Semantic, r::RingBuffer) = r.len
Narcissus.components(::Narcissus.Semantic, r::RingBuffer) =
    (Narcissus.Component("[\$i]", "{}.store[\$i]", r.store[i]) for i in 1:r.len)
```

## The contract

- **Iterable, not necessarily indexable.** The explorer only ever takes a
  window out of the result — `Iterators.drop` then `Iterators.take` — so a lazy
  generator is the right shape and keeps a million-element container cheap. A
  `Vector{Component}` is fine for small values.
- **Stable order.** Iteration order is display order, and it must not change
  between calls for an unchanged value: windowing, the `…` batch loader and
  "re-read this node" all assume that component *n* is the same component next
  time.
- **Agrees with [`component_count`](@ref).** The count decides whether a row
  gets an expansion arrow and where the elision marker goes; a count that
  disagrees with the iterator produces a phantom `… N more` row.
- **Cheap to build.** It is called every time a node is opened, and again for
  each further batch of a long container.
- **Does not throw.** Wrap a failing lookup in [`AccessError`](@ref) so it
  becomes one visible row instead of an error. If the method itself throws,
  the explorer catches it and shows a single error row rather than dying, but
  you lose the other components.

## The two modes

`components(::Fields, x)` is generic — it reads the struct fields Julia
actually stores — and should not normally be specialised.
`components(::Semantic, x)` falls back to it, so a plain struct looks the same
in both modes and only types with something better to say need a method.

Overload [`has_semantic_view`](@ref) to `true` alongside a `Semantic` method,
or the `m` key will not offer the toggle.

See also [`component_count`](@ref), [`is_leaf`](@ref), [`Component`](@ref).
"""
function components end

"""
    component_count(mode::ExplorationMode, x) -> Int

How many parts `x` has, *without materialising any of them*.

Called on every node the explorer creates, so keep it O(1) — `length`, or a
stored count. It decides two things: whether a row gets an expansion arrow at
all, and where the `… N more` marker goes when a container is longer than the
batch size. It must agree with what [`components`](@ref) actually yields.

Returning `0` makes the value a leaf as far as the tree is concerned; see
[`is_leaf`](@ref) for opting out of exploration entirely.
"""
function component_count end

"""
    has_semantic_view(x) -> Bool

Whether `x` decomposes differently in the two [`ExplorationMode`](@ref)s.
`true` puts the `m` toggle on the row and makes the mode visible in the detail
pane. Overload it to `true` alongside your `components(::Semantic, …)` method.

The default answers `true` for anything claimed by
[`register_semantic!`](@ref), so a trait-registered view needs no method here.
"""
function has_semantic_view end

"""
    identity_keys(x) -> Tuple

The object identities the explorer tracks for cycle detection. A plain value
offers itself; a [`Diff`](@ref) offers both of its sides.
"""
identity_keys(@nospecialize(x)) = (x,)

"""
    is_leaf(x) -> Bool

Values the explorer refuses to descend into, in *either* mode, even though
they have fields. Types and modules are the usual offenders: their internals
are deep, cyclic, and almost never what you opened the explorer for.
"""
is_leaf(@nospecialize(x)) = false
is_leaf(::Symbol) = true
is_leaf(::AbstractString) = true
is_leaf(::AbstractChar) = true
is_leaf(::Undef) = true
is_leaf(::AccessError) = true

# ── Trait-based views ────────────────────────────────────────────────

struct SemanticTrait
    applies::Function
    count::Function
    parts::Function
end

const SEMANTIC_TRAITS = SemanticTrait[]

"""
    register_semantic!(applies, count, parts)

Register a semantic view for values that *dispatch cannot select on*.

Most types are served by adding a [`components`](@ref) method. Some ecosystems
decide by trait instead of by type — `Tables.istable(T)` is true for a
`DataFrame` without `DataFrame` sharing an abstract supertype you could
dispatch on — and there is no method signature that captures them. Register the
three functions instead:

- `applies(x)::Bool` — is this one of mine?
- `count(x)::Int` — how many parts, cheaply (see [`component_count`](@ref))
- `parts(x)` — the parts (see [`components`](@ref))

Registrations are consulted in order, only for values no `components` method
already claims, so they never shadow ordinary dispatch. Call this from an
extension's `__init__`.

```julia
Narcissus.register_semantic!(
    x -> Tables.istable(typeof(x)),
    x -> length(Tables.columnnames(Tables.columns(x))),
    x -> (Component(String(n), "Tables.getcolumn({}, :\$n)",
                    Tables.getcolumn(Tables.columns(x), n))
          for n in Tables.columnnames(Tables.columns(x))),
)
```
"""
function register_semantic!(applies::Function, count::Function, parts::Function)
    push!(SEMANTIC_TRAITS, SemanticTrait(applies, count, parts))
    nothing
end

"The registered view claiming `x`, or `nothing`."
function semantic_trait(@nospecialize(x))
    for t in SEMANTIC_TRAITS
        try
            t.applies(x) && return t
        catch
            continue
        end
    end
    nothing
end

# ── Field mode: what Julia actually stores ───────────────────────────

components(::Fields, @nospecialize(x)) = _field_components(x)
component_count(::Fields, @nospecialize(x)) = fieldcount(typeof(x))

# A tuple's "field names" are integers, so it needs its own field view — which
# happens to be identical to its semantic one.
components(::Fields, x::Tuple) = (Component("[$i]", "{}[$i]", x[i]) for i in eachindex(x))
component_count(::Fields, x::Tuple) = length(x)

# ── Types: a map of an unfamiliar package ────────────────────────────

components(::Semantic, T::Type) = _type_components(T)
components(::Fields, T::Type) = _type_components(T)
component_count(::Semantic, T::Type) = _type_count(T)
component_count(::Fields, T::Type) = _type_count(T)
has_semantic_view(::Type) = false

# `fieldcount` throws on anything without a definite layout — abstract types,
# `UnionAll`s, `Union`s — which is exactly the case where there is nothing to
# show anyway.
_type_count(@nospecialize(T::Type)) =
    try
        fieldcount(T)
    catch
        0
    end

function _type_components(@nospecialize(T::Type))
    n = _type_count(T)
    n == 0 && return Component[]
    names = fieldnames(T)
    (_type_component(T, i, names[i]) for i = 1:n)
end

_type_component(@nospecialize(T::Type), i::Int, name::Symbol) =
    Component(String(name), "fieldtype({}, :$name)", fieldtype(T, i); kind = :field)

# A tuple type's field "names" are integers.
_type_component(@nospecialize(T::Type), i::Int, ::Integer) =
    Component("[$i]", "fieldtype({}, $i)", fieldtype(T, i); kind = :index)

# ── Modules: what a package contains ─────────────────────────────────

# `names` walks the module's binding table, and `component_count` is asked once
# per node — so the answer is remembered. New definitions after a fresh
# `include` will not show until the node is reloaded with `r`.
const _MODULE_NAMES = IdDict{Tuple{Module,Bool},Vector{Symbol}}()

"""
    module_names(m::Module; all=false) -> Vector{Symbol}

The bindings of a module: its public API by default, everything it defines
(internals, imports, generated names) when `all`.

The module's own name is dropped — every module exports itself, and a row that
leads straight back to where you are is noise. Memoised; [`forget_modules!`](@ref)
clears the memo.
"""
function module_names(m::Module; all::Bool = false)
    get!(_MODULE_NAMES, (m, all)) do
        me = nameof(m)
        found = try
            names(m; all, imported = all)
        catch
            Symbol[]
        end
        sort!(filter(n -> n !== me && !startswith(String(n), "#"), found))
    end
end

"""
    binding_kind(x) -> Symbol

Which drawer of a module a binding belongs in: `:module`, `:type`, `:macro`,
`:function` or `:value`. What `f` filters a module's listing by, since "show me
the types this package defines" is a different question from "show me
everything".
"""
function binding_kind(@nospecialize(x))
    x isa Module && return :module
    x isa Type && return :type
    x isa Function && return is_macro(x) ? :macro : :function
    :value
end

"""
    is_macro(x) -> Bool

Whether a value is the function behind a macro.

A macro is a function as far as Julia is concerned — `@time` is bound to a
generic function like any other — and the only thing that says otherwise is the
`@` its name starts with. A listing that files `@view` under "functions" is
telling you something true and useless.
"""
is_macro(@nospecialize(x)) = x isa Function && try
    startswith(String(nameof(x)), "@")
catch
    false
end

"The filter categories `f` cycles through, in order."
const BINDING_KINDS = (:all, :function, :macro, :type, :module, :value)

"Plural label for a binding category, for the pane title."
kind_label(kind::Symbol) =
    kind === :all ? "all" : kind === :value ? "values" : string(kind, "s")

"Drop the memoised module binding lists, so newly defined names show up."
forget_modules!() = (empty!(_MODULE_NAMES); nothing)

# A module has two honest views, and they are exactly the two modes: what it
# offers, and everything it contains.
components(::Semantic, m::Module) = _module_components(m, false)
components(::Fields, m::Module) = _module_components(m, true)
component_count(::Semantic, m::Module) = length(module_names(m; all = false))
component_count(::Fields, m::Module) = length(module_names(m; all = true))
has_semantic_view(::Module) = true

function _module_components(m::Module, all::Bool)
    (_module_component(m, n) for n in module_names(m; all))
end

function _module_component(m::Module, name::Symbol)
    s = String(name)
    tpl = Base.isidentifier(s) ? "{}.$s" : "getfield({}, Symbol($(repr(s))))"
    isdefined(m, name) ?
    Component(s, tpl, _tryget(() -> getfield(m, name)); kind = :field) :
    Component(s, tpl, Undef(); kind = :field)
end

# ── Functions: a function is its methods ─────────────────────────────

components(::Semantic, f::Function) = _method_components(f)
component_count(::Semantic, f::Function) = length(methods(f))
# The field view of a function is what the closure captured — usually nothing,
# and interesting exactly when it is not.
has_semantic_view(::Function) = true

function _method_components(@nospecialize(f))
    ms = collect(methods(f))
    (
        Component(_method_key(ms[i]), "collect(methods({}))[$i]", ms[i]; kind = :index) for
        i in eachindex(ms)
    )
end

"""
    _method_key(m::Method) -> String

A method's argument signature, `(::Int64, ::String)`, with the function's own
type dropped — it is the same for every row and the tree already says which
function you are looking at.
"""
function _method_key(m::Method)
    try
        sig = Base.unwrap_unionall(m.sig)
        args = sig.parameters[2:end]
        "(" * join(("::" * string(a) for a in args), ", ") * ")"
    catch
        "(…)"
    end
end

# ── Semantic mode: what the value means ──────────────────────────────

function components(::Semantic, @nospecialize(x))
    t = semantic_trait(x)
    t === nothing ? components(Fields(), x) : t.parts(x)
end

function component_count(::Semantic, @nospecialize(x))
    t = semantic_trait(x)
    t === nothing ? component_count(Fields(), x) : t.count(x)
end

has_semantic_view(@nospecialize(x)) = semantic_trait(x) !== nothing

components(::Semantic, x::AbstractArray) = _array_components(x)
component_count(::Semantic, x::AbstractArray) = length(x)
has_semantic_view(::AbstractArray) = true

components(::Semantic, x::AbstractDict) = (_entry_component(k, v) for (k, v) in x)
component_count(::Semantic, x::AbstractDict) = length(x)
has_semantic_view(::AbstractDict) = true

components(::Semantic, x::AbstractSet) =
    (Component("[$i]", "collect({})[$i]", v) for (i, v) in enumerate(x))
component_count(::Semantic, x::AbstractSet) = length(x)
has_semantic_view(::AbstractSet) = true

# ── Default implementations ──────────────────────────────────────────

function _field_components(@nospecialize(x))
    names = fieldnames(typeof(x))
    (_field_component(x, i, names[i]) for i in eachindex(names))
end

function _field_component(@nospecialize(x), i::Int, name::Symbol)
    s = String(name)
    tpl = _field_template(s)
    isdefined(x, i) ? Component(s, tpl, _tryget(() -> getfield(x, i)); kind = :field) :
    Component(s, tpl, Undef(); kind = :field)
end

function _array_components(x::AbstractArray)
    # Cartesian indices for matrices and up, so the path reads `a[2, 3]`
    # rather than an opaque linear offset.
    idxs = ndims(x) > 1 ? CartesianIndices(x) : eachindex(x)
    (Component(_index_key(i), _index_template(i), _tryget(() -> x[i])) for i in idxs)
end

function _entry_component(@nospecialize(k), @nospecialize(v))
    r = _saferepr(k)
    Component(r, "{}[$r]", v; kind = :key)
end

# ── Accessor templates ───────────────────────────────────────────────

_index_template(i::Integer) = "{}[$i]"
_index_template(i::CartesianIndex) = "{}[" * join(Tuple(i), ", ") * "]"
_index_template(i) = "{}[" * _saferepr(i) * "]"

_index_key(i::Integer) = "[$i]"
_index_key(i::CartesianIndex) = "[" * join(Tuple(i), ", ") * "]"
_index_key(i) = "[" * _saferepr(i) * "]"

function _field_template(name::String)
    Base.isidentifier(name) ? "{}.$name" : "getfield({}, Symbol($(repr(name))))"
end

_saferepr(x) =
    try
        repr(x)
    catch
        string(typeof(x)) * "(…)"
    end

_tryget(f) =
    try
        f()
    catch e
        AccessError(e)
    end

# ═══════════════════════════════════════════════════════════════════════
# What the explorer calls
# ═══════════════════════════════════════════════════════════════════════

"""
    n_components(mode, x) -> Int

[`component_count`](@ref), guarded: leaves and types with a throwing
`component_count` report `0` rather than taking the app down.
"""
function n_components(mode::ExplorationMode, @nospecialize(x))
    is_leaf(x) && return 0
    try
        max(0, component_count(mode, x))
    catch
        0
    end
end

"Whether the tree should offer to expand `x` in `mode`."
expandable(mode::ExplorationMode, @nospecialize(x)) = n_components(mode, x) > 0

"""
    component_window(mode, x, start, limit) -> Vector{Component}

The components of `x` numbered `start` through `start + limit - 1`, in
iteration order. Taking a window (rather than everything) is what keeps a
million-element array browsable: the tree only ever holds one slice of it.
"""
function component_window(mode::ExplorationMode, @nospecialize(x), start::Int, limit::Int)
    (limit < 1 || start < 1 || is_leaf(x)) && return Component[]
    it = try
        components(mode, x)
    catch e
        return Component[Component("!", "{}", AccessError(e))]
    end
    try
        collect(Component, Iterators.take(Iterators.drop(it, start - 1), limit))
    catch e
        Component[Component("!", "{}", AccessError(e))]
    end
end
