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

One part of a decomposed value, as returned by [`components`](@ref).

- `key` is the label shown in the tree (`"data"`, `"[3]"`, `":name"`).
- `template` is the Julia expression that reaches this component from its
  parent, with `{}` standing in for the parent's own path expression:
  `"{}.data"`, `"{}[3]"`, `"collect({})[2]"`. Whatever you write here is what
  `y` copies to the clipboard, so it should be pasteable.
- `kind` colours the key in the tree: `:field`, `:index` or `:key`.
"""
struct Component
    key::String
    template::String
    value::Any
    kind::Symbol
end

Component(key::AbstractString, template::AbstractString, value; kind::Symbol=:index) =
    Component(String(key), String(template), value, kind)

# ═══════════════════════════════════════════════════════════════════════
# The interface
# ═══════════════════════════════════════════════════════════════════════

"""
    components(mode::ExplorationMode, x) -> iterable of Component

List the parts of `x`. **This is the extension point**: give your type a
`components(::Semantic, ::MyType)` method to control how the explorer walks it.

The result must be *iterable* but need not be a `Vector` — the explorer only
ever takes a window out of it (`limit` elements at a time), so returning a lazy
generator keeps large containers cheap. Pair it with [`component_count`](@ref)
and [`has_semantic_view`](@ref):

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

`components(::Fields, x)` is generic — it reads the struct fields Julia
actually stores — and should not normally be specialised. `components(::Semantic, x)`
falls back to it, so a plain struct looks the same in both modes.
"""
function components end

"""
    component_count(mode::ExplorationMode, x) -> Int

How many parts `x` has, *without materialising any of them*. Called on every
node the explorer creates, so keep it O(1); it decides whether a row gets an
expansion arrow and where the `…` elision marker goes.
"""
function component_count end

"""
    has_semantic_view(x) -> Bool

Whether `x` decomposes differently in the two [`ExplorationMode`](@ref)s.
`true` puts the `m` toggle on the row and makes the mode visible in the detail
pane. Overload it to `true` alongside your `components(::Semantic, …)` method.
"""
has_semantic_view(@nospecialize(x)) = false

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
is_leaf(::Type) = true
is_leaf(::Module) = true
is_leaf(::Symbol) = true
is_leaf(::AbstractString) = true
is_leaf(::AbstractChar) = true
is_leaf(::Undef) = true
is_leaf(::AccessError) = true

# ── Field mode: what Julia actually stores ───────────────────────────

components(::Fields, @nospecialize(x)) = _field_components(x)
component_count(::Fields, @nospecialize(x)) = fieldcount(typeof(x))

# A tuple's "field names" are integers, so it needs its own field view — which
# happens to be identical to its semantic one.
components(::Fields, x::Tuple) =
    (Component("[$i]", "{}[$i]", x[i]) for i in 1:length(x))
component_count(::Fields, x::Tuple) = length(x)

# ── Semantic mode: what the value means ──────────────────────────────

components(::Semantic, @nospecialize(x)) = components(Fields(), x)
component_count(::Semantic, @nospecialize(x)) = component_count(Fields(), x)

components(::Semantic, x::AbstractArray) = _array_components(x)
component_count(::Semantic, x::AbstractArray) = length(x)
has_semantic_view(::AbstractArray) = true

components(::Semantic, x::AbstractDict) =
    (_entry_component(k, v) for (k, v) in x)
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
    isdefined(x, i) ? Component(s, tpl, _tryget(() -> getfield(x, i)); kind=:field) :
    Component(s, tpl, Undef(); kind=:field)
end

function _array_components(x::AbstractArray)
    # Cartesian indices for matrices and up, so the path reads `a[2, 3]`
    # rather than an opaque linear offset.
    idxs = ndims(x) > 1 ? CartesianIndices(x) : eachindex(x)
    (Component(_index_key(i), _index_template(i), _tryget(() -> x[i])) for i in idxs)
end

function _entry_component(@nospecialize(k), @nospecialize(v))
    r = _saferepr(k)
    Component(r, "{}[$r]", v; kind=:key)
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

_saferepr(x) = try
    repr(x)
catch
    string(typeof(x)) * "(…)"
end

_tryget(f) = try
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
function component_window(mode::ExplorationMode, @nospecialize(x),
                          start::Int, limit::Int)
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
