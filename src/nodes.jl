# ═══════════════════════════════════════════════════════════════════════
# ObjNode ── one lazily-expanded row of the object tree
# ═══════════════════════════════════════════════════════════════════════

"Default number of children materialised per container before eliding."
const DEFAULT_LIMIT = 100

"""
    ObjNode

A node in the exploration tree. Children are materialised only when a node is
first expanded, so opening the explorer on a deeply nested (or self
referential, or huge) object costs nothing until you actually walk into it.

Each node also carries its own [`ExplorationMode`](@ref): a `Dict` can be
shown as its entries or as its raw fields, and the nodes opened underneath it
inherit whichever was chosen.

`kind` is one of:
- `:root`    — the object handed to [`narcissus`](@ref)
- `:field`   — a struct field
- `:index`   — an array/tuple/set element
- `:key`     — a dictionary entry
- `:cycle`   — a value already present among this node's ancestors
- `:elided`  — the `… N more` stand-in for a truncated container
"""
mutable struct ObjNode
    key::String
    kind::Symbol
    value::Any
    path::String
    parent::Union{Nothing,ObjNode}
    children::Vector{ObjNode}
    expanded::Bool
    loaded::Bool
    expandable::Bool
    mode::ExplorationMode
    index::Int          # position among the parent's children (0 for a root)
    total::Int          # child count of `value` (`:elided`: of the container)
    next_start::Int     # `:elided` only — index to resume from
    limit::Int
    _preview::Union{Nothing,String}
    _status::Union{Nothing,Symbol}
    _anomaly::Union{Nothing,Symbol}   # `nothing` = not computed; `:none` = clean
    _bytes::Int                       # -1 = not computed
    _bytes_capped::Bool               # measurement hit the budget
end

function ObjNode(key::AbstractString, value, path::AbstractString;
                 kind::Symbol=:root, parent=nothing, index::Int=0,
                 mode::ExplorationMode=Semantic(), limit::Int=DEFAULT_LIMIT)
    ObjNode(String(key), kind, value, String(path), parent, ObjNode[],
            false, false, expandable(mode, value), mode, index,
            n_components(mode, value), 0, limit, nothing, nothing, nothing,
            -1, false)
end

"Root node for `value`, displayed and path-rooted as `name`."
root_node(value, name::AbstractString="obj"; limit::Int=DEFAULT_LIMIT,
          mode::ExplorationMode=Semantic()) =
    ObjNode(name, value, name; kind=:root, mode, limit)

# ── Cycles ───────────────────────────────────────────────────────────

"""
    is_ancestor_value(parent, v) -> Bool

`true` when `v` is (identically) one of the values already on the path from
the root. Self-referential structures are common enough — a node holding its
parent, a graph, a closure over its own container — that walking into one
blindly would hang the explorer.
"""
function is_ancestor_value(parent::Union{Nothing,ObjNode}, @nospecialize(v))
    keys = identity_keys(v)
    all(_opaque, keys) && return false
    p = parent
    while p !== nothing
        if p.kind !== :elided
            pkeys = identity_keys(p.value)
            length(pkeys) == length(keys) &&
                any(i -> _ident(pkeys[i], keys[i]), eachindex(keys)) && return true
        end
        p = p.parent
    end
    false
end

# Only heap values have an identity worth chasing; `1 === 1` says nothing.
_opaque(@nospecialize(v)) = isbits(v) || is_leaf(v)
_ident(@nospecialize(a), @nospecialize(b)) = !_opaque(a) && a === b

# ── Building ─────────────────────────────────────────────────────────

# Children inherit their parent's mode: dropping a node into field mode means
# you meant to spelunk the storage below it, not just at it.
function make_node(c::Component, parent::ObjNode, index::Int)
    path = replace(c.template, "{}" => parent.path)
    mode = parent.mode
    if is_ancestor_value(parent, c.value)
        n = ObjNode(c.key, c.value, path; kind=:cycle, parent, index, mode,
                    limit=parent.limit)
        n.expandable = false
        return n
    end
    ObjNode(c.key, c.value, path; kind=c.kind, parent, index, mode,
            limit=parent.limit)
end

function elided_node(parent::ObjNode, next_start::Int)
    n = ObjNode("…", parent.value, parent.path; kind=:elided, parent,
                mode=parent.mode, limit=parent.limit)
    n.next_start = next_start
    n.total = parent.total
    n.expandable = true
    n
end

"""
    load_children!(node) -> node

Materialise `node`'s first window of children. Idempotent.
"""
function load_children!(n::ObjNode)
    n.loaded && return n
    n.children = ObjNode[]
    n.loaded = true
    n.expandable || return n
    append_children!(n, 1)
    n
end

"Append the window of children starting at `start`, plus an elision marker."
function append_children!(n::ObjNode, start::Int)
    kids = component_window(n.mode, n.value, start, n.limit)
    for (i, c) in enumerate(kids)
        push!(n.children, make_node(c, n, start + i - 1))
    end
    shown = start - 1 + length(kids)
    if n.total > shown && !isempty(kids)
        push!(n.children, elided_node(n, shown + 1))
    end
    n
end

"""
    refresh_value!(node) -> Bool

Re-read `node`'s own value out of its parent, so a node that was created
before the object mutated shows what is there now. Returns `true` if the
value could be re-read.
"""
function refresh_value!(n::ObjNode)
    p = n.parent
    (p === nothing || n.index < 1 || n.kind === :elided) && return false
    kids = component_window(p.mode, p.value, n.index, 1)
    (isempty(kids) || kids[1].key != n.key) && return false
    n.value = kids[1].value
    n._preview = nothing
    n._status = nothing
    n._anomaly = nothing
    n._bytes = -1
    n._bytes_capped = false
    n.total = n_components(n.mode, n.value)
    n.expandable = expandable(n.mode, n.value)
    true
end

"""
    set_mode!(node, mode) -> Bool

Show `node` in a different [`ExplorationMode`](@ref), discarding the children
it had listed under the old one. Returns `true` if anything changed.
"""
function set_mode!(n::ObjNode, mode::ExplorationMode)
    (n.mode === mode || n.kind === :elided) && return false
    n.mode = mode
    n.total = n_components(mode, n.value)
    n.expandable = expandable(mode, n.value)
    if n.loaded
        n.loaded = false
        n.children = ObjNode[]
        load_children!(n)
    end
    n.expanded = n.expanded && n.expandable
    true
end

"""
    toggle_mode!(node) -> Bool

Flip `node` between its semantic and field views. Only values that answer
[`has_semantic_view`](@ref) with `true` have two views to flip between.
"""
function toggle_mode!(n::ObjNode)
    has_semantic_view(n.value) || return false
    set_mode!(n, other_mode(n.mode))
end

"""
    expand_elided!(node) -> ObjNode

Replace a `… N more` marker with the next window of its parent's children.
Returns the parent.
"""
function expand_elided!(n::ObjNode)
    n.kind === :elided || return n
    p = n.parent
    p === nothing && return n
    filter!(c -> c !== n, p.children)
    append_children!(p, n.next_start)
    p
end

"""
    toggle!(node) -> Bool

Expand or collapse `node`, loading its children on first expansion.
Returns `true` if the tree shape changed.
"""
function toggle!(n::ObjNode)
    n.kind === :elided && (expand_elided!(n); return true)
    n.expandable || return false
    if n.expanded
        n.expanded = false
    else
        load_children!(n)
        n.expanded = true
    end
    true
end

"""
    expand_recursive!(node, depth)

Expand `node` and everything beneath it down to `depth` extra levels. Elision
markers are left alone — bulk-expanding is a convenience, not a way to
accidentally materialise a million rows.
"""
function expand_recursive!(n::ObjNode, depth::Int)
    depth < 0 && return n
    (n.expandable && n.kind !== :elided) || return n
    load_children!(n)
    n.expanded = true
    for c in n.children
        expand_recursive!(c, depth - 1)
    end
    n
end

function collapse_recursive!(n::ObjNode)
    n.expanded = false
    for c in n.children
        collapse_recursive!(c)
    end
    n
end

"""
    node_status(node) -> Symbol

[`diff_status`](@ref) of a comparison node, cached, or `:none` when the node
holds an ordinary value. Cached because the status is asked for on every
rendered frame but costs an `isequal` over the whole value to compute.
"""
function node_status(n::ObjNode)
    n._status === nothing || return n._status
    n._status = n.value isa Diff ? diff_status(n.value, n.mode) : :none
end

"""
    node_anomaly(node) -> Union{Nothing,Symbol}

[`anomaly`](@ref) of a node's value, cached, computing it if it has not been
computed yet. Arrays are scanned to answer this, which is why the answer is
kept — and why the renderer asks [`anomaly_state`](@ref) instead.
"""
function node_anomaly(n::ObjNode)
    # A `… N more` marker carries its parent's container, not a value of its
    # own. Flagging it means "there is a NaN somewhere in the rest of this",
    # which is already what the row above says and is not a place to put the
    # cursor; skipping it is also what lets `a` walk on into the tail.
    n.kind === :elided && return nothing
    n._anomaly === nothing || return n._anomaly === :none ? nothing : n._anomaly
    a = n.value isa Diff ? nothing : anomaly(n.value)
    n._anomaly = something(a, :none)
    a
end

"""
    anomaly_state(node) -> Symbol

`:pending` if nobody has looked yet, `:none` if the value is fine, otherwise
the [`anomaly`](@ref).

The renderer uses this rather than [`node_anomaly`](@ref) so that drawing a
frame never scans a million-element array: it draws what is known and asks for
the rest to be worked out off the main task.
"""
anomaly_state(n::ObjNode) = n._anomaly === nothing ? :pending : n._anomaly

"Record an anomaly computed elsewhere."
set_anomaly!(n::ObjNode, a::Union{Nothing,Symbol}) = (n._anomaly = something(a, :none))

"""
    node_bytes(node) -> Int

[`bounded_size`](@ref) of a node's value, cached, computing it if needed.
`node._bytes_capped` records whether the walk ran out of budget, in which case
the number is a lower bound.
"""
function node_bytes(n::ObjNode)
    n._bytes >= 0 && return n._bytes
    n._bytes, n._bytes_capped = bounded_size(node_measurand(n))
    n._bytes
end

"What a node's size is a size *of* — the left side, for a comparison."
node_measurand(n::ObjNode) = n.value isa Diff ? n.value.x : n.value

"`-1` while nobody has measured this node yet."
bytes_state(n::ObjNode) = n._bytes

"Record a size computed elsewhere."
function set_bytes!(n::ObjNode, (bytes, capped)::Tuple{Int,Bool})
    n._bytes = bytes
    n._bytes_capped = capped
end

"""
    expand_differences!(node, depth)

Open the branches that differ and leave the identical ones folded, down to
`depth` extra levels. This is what a freshly opened `narcissus(x, y)` shows:
the shape of the difference, with everything that matches out of the way.
"""
function expand_differences!(n::ObjNode, depth::Int)
    depth < 0 && return n
    n.value isa Diff || return expand_recursive!(n, depth)
    is_difference(node_status(n)) || return n
    (n.expandable && n.kind !== :elided) || return n
    load_children!(n)
    n.expanded = true
    for c in n.children
        expand_differences!(c, depth - 1)
    end
    n
end

depth_of(n::ObjNode) = n.parent === nothing ? 0 : depth_of(n.parent) + 1

# ── Flattening ───────────────────────────────────────────────────────

"One visible line of the tree, with the ancestry needed to draw connectors."
struct Row
    node::ObjNode
    depth::Int
    is_last::Bool
    parent_lasts::Vector{Bool}
end

"""
    flatten(root; hide_same=false, kinds=:all) -> Vector{Row}

The currently visible rows, in display order.

Both filters drop *rows*, never components, so the elision arithmetic of a long
container is untouched: a hidden subtree is simply never walked.

- `hide_same` drops the branches a comparison found identical.
- `kinds` keeps only one [`binding_kind`](@ref) beneath module nodes, which is
  how "show me just the types this package defines" is answered. It applies
  only under modules — elsewhere a listing of one kind is not a question anyone
  is asking.
"""
function flatten(root::ObjNode; hide_same::Bool=false, kinds::Symbol=:all)
    rows = Row[]
    _flatten!(rows, root, 0, true, Bool[], hide_same, kinds)
    rows
end

function _flatten!(rows, n::ObjNode, depth, is_last, parent_lasts, hide_same, kinds)
    push!(rows, Row(n, depth, is_last, copy(parent_lasts)))
    n.expanded || return rows

    kids = n.children
    hide_same && (kids = filter(c -> node_status(c) !== :same, kids))
    kinds === :all || !(n.value isa Module) ||
        (kids = filter(c -> binding_kind(c.value) === kinds, kids))

    lasts = vcat(parent_lasts, is_last)
    for (i, c) in enumerate(kids)
        _flatten!(rows, c, depth + 1, i == length(kids), lasts, hide_same, kinds)
    end
    rows
end

"""
    find_node(root, predicate; budget=SEARCH_BUDGET, maxdepth=32) -> Union{Nothing,ObjNode}

Walk the tree in display order looking for a node `predicate` accepts, opening
children as it goes.

This is the escalation behind `/` and `a`: the visible rows are searched first
because that is instant, and only when nothing matches does the explorer go
looking in the parts of the object it has not read yet. The walk is capped at
`budget` nodes and `maxdepth` levels, because the whole point of the lazy tree
is to never be obliged to read all of a large object.

The tail of a truncated container is searched as well — the elements behind a
`… N more` marker are as much part of the object as the first hundred — but
through [`find_in_tail`](@ref), which does not pull them into the tree.
"""
function find_node(root::ObjNode, predicate; budget::Ref{Int}=Ref(SEARCH_BUDGET),
                   maxdepth::Int=32, skip::Union{Nothing,ObjNode}=nothing)
    (budget[] -= 1) < 0 && return nothing
    maxdepth < 0 && return nothing
    root !== skip && predicate(root) && return root
    root.expandable || return nothing
    root.kind === :elided &&
        return find_in_tail(root, predicate; budget, maxdepth, skip)
    load_children!(root)
    for c in root.children
        found = find_node(c, predicate; budget, maxdepth = maxdepth - 1, skip)
        found === nothing || return found
    end
    nothing
end

"""
    find_in_tail(marker, predicate; budget, maxdepth, skip) -> Union{Nothing,ObjNode}

Search the components a `… N more` marker stands in for, and materialise only
the branch that matches.

Candidates are built *detached* from the tree and thrown away again, so a
search that comes up empty leaves the container exactly as truncated as it
found it — the alternative, expanding window after window as the walk goes,
answers "no match" by having quietly grown a thousand rows onto the screen. A
hit is then loaded for real, one window at a time up to the element that
matched, and looked up again in the tree proper: the same walk, on nodes that
are actually there for the cursor to land on.

The elements are read in `limit`-sized windows and every candidate costs a
node of the shared `budget`, so a search over a million-element array stops
where any other search stops.
"""
function find_in_tail(marker::ObjNode, predicate; budget::Ref{Int},
                      maxdepth::Int, skip::Union{Nothing,ObjNode})
    parent = marker.parent
    parent === nothing && return nothing
    start = marker.next_start
    while start <= marker.total && budget[] >= 0
        window = component_window(parent.mode, parent.value, start, parent.limit)
        isempty(window) && break
        for (i, c) in enumerate(window)
            index = start + i - 1
            # Siblings of the marker, so tested at the marker's own depth.
            probe = make_node(c, parent, index)
            find_node(probe, predicate; budget, maxdepth, skip) === nothing ||
                return realise_child!(parent, index, predicate, maxdepth, skip)
        end
        start += length(window)
    end
    nothing
end

"Load a truncated container up to `index`, and find the match inside it again."
function realise_child!(parent::ObjNode, index::Int, predicate, maxdepth::Int,
                        skip::Union{Nothing,ObjNode})
    while index > length(parent.children) ||
          parent.children[index].kind === :elided
        tail = last(parent.children)
        tail.kind === :elided || break
        expand_elided!(tail)
    end
    index <= length(parent.children) || return nothing
    # A fresh budget: this walk covers ground already paid for, and running out
    # of it here would report "no match" for something just found.
    find_node(parent.children[index], predicate;
              budget = Ref(SEARCH_BUDGET), maxdepth, skip)
end

"""
    SEARCH_BUDGET

How many nodes a deep search may visit before giving up.

The walk materialises every node it touches and renders every leaf it tests, so
this bounds both how long a search can block the UI and how much tree it can
grow behind your back. Warm, a full budget costs on the order of 70ms; the
first walk over a shape of object never seen before is slower, and that is
Julia compiling the decomposition, not the search.
"""
const SEARCH_BUDGET = 20_000

"""
    reveal!(node)

Expand every ancestor of `node` so that it becomes a visible row.
"""
function reveal!(n::ObjNode)
    p = n.parent
    while p !== nothing
        p.expanded = true
        p = p.parent
    end
    n
end
