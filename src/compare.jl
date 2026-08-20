# ═══════════════════════════════════════════════════════════════════════
# Diff ── comparing two objects is just another kind of value
# ═══════════════════════════════════════════════════════════════════════

"""
    Absent

The stand-in for a component that exists on only one side of a [`Diff`](@ref):
a key one dictionary has and the other does not, or the tail of the longer of
two arrays.
"""
struct Absent end

is_leaf(::Absent) = true

"""
    Diff(x, y)

A pair of values under comparison. Narcissus treats it as a value in its own
right: it decomposes by zipping the components of `x` and `y` together, so the
whole explorer — lazy expansion, elision of long containers, cycle detection,
and the semantic/field mode toggle — works on a comparison unchanged.

Whatever you leave the cursor on when you quit `narcissus(x, y)` comes back as
one of these; reach the two sides through `.x` and `.y`.
"""
struct Diff
    x::Any
    y::Any
end

Base.show(io::IO, d::Diff) = print(io, "Diff(", repr(d.x), ", ", repr(d.y), ")")

identity_keys(d::Diff) = (d.x, d.y)

"""
    comparable(a, b) -> Bool

Whether two values are similar enough to line their components up. Values of
differently *named* types are not: `Foo` against `Bar` is reported as a type
change rather than zipped field by field. Type *parameters* may differ freely,
since `Foo{Int}` and `Foo{Float64}` still have the same fields.
"""
function comparable(@nospecialize(a), @nospecialize(b))
    (a isa Absent || b isa Absent) && return false
    nameof(typeof(a)) === nameof(typeof(b))
end

_safe_isequal(@nospecialize(a), @nospecialize(b)) = try
    isequal(a, b)
catch
    a === b
end

# ── Structural equality ──────────────────────────────────────────────

"How many component comparisons a single equality test may cost."
const EQUALITY_BUDGET = 100_000

"How deep a structural comparison may recurse before giving up."
const EQUALITY_DEPTH = 64

_generic_eq(@nospecialize(T::Type)) = try
    which(==, Tuple{T,T}).sig === Tuple{typeof(==),Any,Any}
catch
    true
end

const _TRUST_CACHE = IdDict{Type,Bool}()

"""
    trustworthy_equality(T) -> Bool

Whether `isequal` on `T` answers the question a diff is actually asking.

It does not for a `mutable struct`, where `==` falls back to `===` and two
field-by-field identical objects compare unequal — nor for a container of
them, since `==` on a `Vector` defers to its elements. For those, Narcissus
compares component by component instead, which is both the slower path and
the one that tells you something. Types that define their own `==` (numbers,
strings, arrays of bits types) are taken at their word.

Memoised per type: the answer needs `which`, a runtime method lookup costing
microseconds, and it is asked once per value comparison.
"""
trustworthy_equality(@nospecialize(T::Type)) =
    get!(() -> _trustworthy_equality(T), _TRUST_CACHE, T)

function _trustworthy_equality(@nospecialize(T::Type))
    # `===` is structural for bits types and identity is the right answer for
    # interned ones, so the generic fallback is trustworthy after all.
    isbitstype(T) && return true
    T <: Union{Symbol,Module,Type,AbstractString,AbstractChar} && return true
    _generic_eq(T) && return false
    T <: AbstractArray && return trustworthy_equality(eltype(T))
    T <: AbstractSet && return trustworthy_equality(eltype(T))
    T <: AbstractDict &&
        return trustworthy_equality(keytype(T)) && trustworthy_equality(valtype(T))
    (T <: Tuple || T <: NamedTuple) && isconcretetype(T) &&
        return all(trustworthy_equality, fieldtypes(T))
    true
end

"""
    same_value(mode, a, b) -> Bool

Whether `a` and `b` are the same as far as the explorer is concerned: `isequal`
where that is meaningful (see [`trustworthy_equality`](@ref)), and a recursive
walk over their components where it is not.

The walk is bounded by [`EQUALITY_BUDGET`](@ref) comparisons and
[`EQUALITY_DEPTH`](@ref) levels. Exhausting either reports "not the same",
which shows the branch as changed and leaves you to look — the honest answer
when the question got too expensive to settle.
"""
same_value(mode::ExplorationMode, @nospecialize(a), @nospecialize(b)) =
    _same(mode, a, b, Ref(EQUALITY_BUDGET), 0)

function _same(mode::ExplorationMode, @nospecialize(a), @nospecialize(b),
               budget::Ref{Int}, depth::Int)
    a === b && return true
    (budget[] -= 1) < 0 && return false
    depth > EQUALITY_DEPTH && return false
    comparable(a, b) || return false

    T = typeof(a)
    T === typeof(b) && trustworthy_equality(T) && return _safe_isequal(a, b)
    (is_leaf(a) || is_leaf(b)) && return _safe_isequal(a, b)

    _same_parts(mode, a, b, budget, depth)
end

# Built-in containers are walked directly rather than through `components`:
# same answer, without allocating a Component per element.
function _same_parts(mode::ExplorationMode, @nospecialize(a), @nospecialize(b),
                     budget::Ref{Int}, depth::Int)
    if mode isa Semantic
        a isa AbstractArray && b isa AbstractArray &&
            return _same_array(mode, a, b, budget, depth)
        a isa AbstractDict && b isa AbstractDict &&
            return _same_dict(mode, a, b, budget, depth)
        a isa AbstractSet && b isa AbstractSet && return issetequal(a, b)
        # A type with a hand-written semantic view is compared through it.
        has_semantic_view(a) && return _same_via_components(mode, a, b, budget, depth)
    end
    _same_fields(mode, a, b, budget, depth)
end

function _same_array(mode, a, b, budget::Ref{Int}, depth::Int)
    axes(a) == axes(b) || return false
    for i in eachindex(a)
        # Unassigned slots are a real difference when only one side has one,
        # and reading either would throw — so ask before reaching in.
        ea, eb = _tryget(() -> a[i]), _tryget(() -> b[i])
        readable = !(ea isa AccessError)
        readable == !(eb isa AccessError) || return false
        readable || continue
        _same(mode, ea, eb, budget, depth + 1) || return false
        budget[] < 0 && return false
    end
    true
end

function _same_dict(mode, a, b, budget::Ref{Int}, depth::Int)
    length(a) == length(b) || return false
    for (k, v) in a
        haskey(b, k) || return false
        _same(mode, v, b[k], budget, depth + 1) || return false
        budget[] < 0 && return false
    end
    true
end

function _same_fields(mode, @nospecialize(a), @nospecialize(b),
                      budget::Ref{Int}, depth::Int)
    Ta, Tb = typeof(a), typeof(b)
    fieldnames(Ta) == fieldnames(Tb) || return false
    for i in 1:fieldcount(Ta)
        da, db = isdefined(a, i), isdefined(b, i)
        da == db || return false
        da || continue
        _same(mode, getfield(a, i), getfield(b, i), budget, depth + 1) || return false
        budget[] < 0 && return false
    end
    true
end

function _same_via_components(mode, @nospecialize(a), @nospecialize(b),
                              budget::Ref{Int}, depth::Int)
    n_components(mode, a) == n_components(mode, b) || return false
    for c in components(mode, Diff(a, b))
        c.value isa Diff || continue
        _same(mode, c.value.x, c.value.y, budget, depth + 1) || return false
        budget[] < 0 && return false
    end
    true
end

# ═══════════════════════════════════════════════════════════════════════
# Status
# ═══════════════════════════════════════════════════════════════════════

"""
    diff_status(d::Diff, mode=Semantic()) -> Symbol

What happened between the two sides:

| Status     | Meaning                                        |
|:-----------|:-----------------------------------------------|
| `:same`    | the two sides are the same, structurally       |
| `:changed` | same shape, different contents                 |
| `:added`   | present on the right only                      |
| `:removed` | present on the left only                       |
| `:type`    | the two sides are values of unrelated types    |

Equality is [`same_value`](@ref), not plain `isequal`, so two `deepcopy`-equal
mutable structs come back `:same`. It walks the value, so the explorer caches
the answer per node rather than asking once per frame.
"""
function diff_status(d::Diff, mode::ExplorationMode=Semantic())
    d.x isa Absent && return :added
    d.y isa Absent && return :removed
    comparable(d.x, d.y) || return :type
    same_value(mode, d.x, d.y) ? :same : :changed
end

"Whether a status is worth stopping on when jumping between differences."
is_difference(status::Symbol) = status !== :same && status !== :none

# ═══════════════════════════════════════════════════════════════════════
# The interface, for a pair of values
# ═══════════════════════════════════════════════════════════════════════

# A comparison bottoms out where there is nothing left to line up.
is_leaf(d::Diff) = !comparable(d.x, d.y) || (is_leaf(d.x) && is_leaf(d.y))

has_semantic_view(d::Diff) =
    !is_leaf(d) && (has_semantic_view(d.x) || has_semantic_view(d.y))

components(::Fields, d::Diff) = _zip_components(Fields(), d)
component_count(::Fields, d::Diff) = _zip_count(Fields(), d)

function components(::Semantic, d::Diff)
    is_leaf(d) && return Component[]
    d.x isa AbstractDict && d.y isa AbstractDict &&
        return _dict_diff_components(d.x, d.y)
    d.x isa AbstractSet && d.y isa AbstractSet &&
        return _set_diff_components(d.x, d.y)
    _zip_components(Semantic(), d)
end

function component_count(::Semantic, d::Diff)
    is_leaf(d) && return 0
    if d.x isa AbstractDict && d.y isa AbstractDict
        return length(d.x) + count(k -> !haskey(d.x, k), keys(d.y))
    elseif d.x isa AbstractSet && d.y isa AbstractSet
        return length(d.x) + count(v -> !(v in d.x), d.y)
    end
    _zip_count(Semantic(), d)
end

# ── Positional pairing: arrays, tuples, structs, all of field mode ───

const ABSENT_COMPONENT = Component("", "{}", Absent(), :absent)

_side_count(mode::ExplorationMode, @nospecialize(v)) = n_components(mode, v)
_side_components(mode::ExplorationMode, @nospecialize(v)) =
    is_leaf(v) ? Component[] : components(mode, v)

_zip_count(mode::ExplorationMode, d::Diff) =
    is_leaf(d) ? 0 : max(_side_count(mode, d.x), _side_count(mode, d.y))

function _zip_components(mode::ExplorationMode, d::Diff)
    is_leaf(d) && return Component[]
    nx, ny = _side_count(mode, d.x), _side_count(mode, d.y)
    n = max(nx, ny)
    xs = _pad(_side_components(mode, d.x), n - nx)
    ys = _pad(_side_components(mode, d.y), n - ny)
    (_pair(cx, cy) for (cx, cy) in zip(xs, ys))
end

# Pad the shorter side so `zip` lines up the whole union, not the overlap.
_pad(it, k::Int) =
    k <= 0 ? it : Iterators.flatten((it, Iterators.repeated(ABSENT_COMPONENT, k)))

function _pair(cx::Component, cy::Component)
    present = cx.kind === :absent ? cy : cx
    Component(present.key, present.template, Diff(cx.value, cy.value); kind=present.kind)
end

# ── Key pairing: dictionaries and sets in semantic mode ──────────────

function _dict_diff_components(x::AbstractDict, y::AbstractDict)
    shared = (_entry_diff(k, x[k], get(y, k, Absent())) for k in keys(x))
    added = (_entry_diff(k, Absent(), y[k]) for k in keys(y) if !haskey(x, k))
    Iterators.flatten((shared, added))
end

function _entry_diff(@nospecialize(k), @nospecialize(vx), @nospecialize(vy))
    r = _saferepr(k)
    Component(r, "{}[$r]", Diff(vx, vy); kind=:key)
end

# A set has no index to point at, so a member's path is the set itself.
function _set_diff_components(x::AbstractSet, y::AbstractSet)
    shared = (Component(_saferepr(v), "{}", Diff(v, v in y ? v : Absent()); kind=:key)
              for v in x)
    added = (Component(_saferepr(v), "{}", Diff(Absent(), v); kind=:key)
             for v in y if !(v in x))
    Iterators.flatten((shared, added))
end
