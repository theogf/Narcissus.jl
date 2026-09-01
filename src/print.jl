# ═══════════════════════════════════════════════════════════════════════
# Printing ── the same decomposition, without a terminal to drive
# ═══════════════════════════════════════════════════════════════════════

# `children` loads on demand, so an unbounded walk would read the whole object.
# Every entry point here passes a `maxdepth`, and `print_tree` enforces it.
AbstractTrees.children(n::ObjNode) = (load_children!(n); n.children)
AbstractTrees.printnode(io::IO, n::ObjNode) = _printnode(io, n)
AbstractTrees.nodevalue(n::ObjNode) = n.value

"""
    Differing(node)

A view of an [`ObjNode`](@ref) whose children are only the ones that differ.
Wrapping rather than filtering in place keeps the tree itself intact — the same
node can be printed whole a moment later.
"""
struct Differing
    node::ObjNode
end

function AbstractTrees.children(d::Differing)
    load_children!(d.node)
    [Differing(c) for c in d.node.children if node_status(c) !== :same]
end

AbstractTrees.printnode(io::IO, d::Differing) = _printnode(io, d.node)

"Theme colour as something `printstyled` accepts (it takes 0:255 directly)."
_ansi(style::Style) = style.fg isa Color256 ? Int(style.fg.code) : :normal

function _printnode(io::IO, n::ObjNode)
    status = node_status(n)
    if status !== :none
        glyph, gstyle = status_marker(status)
        glyph == ' ' || printstyled(io, glyph, ' '; color = _ansi(gstyle), bold = true)
    end
    printstyled(io, n.key; color = _ansi(key_style(n)), bold = true)

    ty = type_string(n)
    isempty(ty) || printstyled(io, "::", ty; color = _ansi(tstyle(:secondary)))

    for (text, style) in preview_spans(n)
        isempty(text) && continue
        printstyled(io, " ", text; color = _ansi(style))
    end
    nothing
end

"""
    print_object([io], obj; name="obj", maxdepth=3, limit=20, mode=:semantic)

Print the object tree instead of opening a terminal UI — for a log, a CI run, a
notebook, or a quick look that does not deserve a full-screen app.

`maxdepth` is what keeps this honest: the tree loads children as it is walked,
so an unbounded print would read all of a large object. Anything past the
depth, or past `limit` elements of a container, is simply not visited.

```julia
julia> print_object(model; maxdepth=2)
model::Model
└─ layers::Vector{Layer}
   ├─ [1]::Layer = Layer([0.1 0.2; …], [0.0, 0.0])
   └─ [2]::Layer = Layer([0.5 0.1], [0.0])
```
"""
function print_object(
    io::IO,
    @nospecialize(obj);
    name::AbstractString = "obj",
    maxdepth::Int = 3,
    limit::Int = 20,
    mode = Semantic(),
)
    root = root_node(obj, name; limit, mode = exploration_mode(mode))
    AbstractTrees.print_tree(_printnode, io, root; maxdepth)
    nothing
end

print_object(@nospecialize(obj); kwargs...) = print_object(stdout, obj; kwargs...)

"""
    print_diff([io], x, y; names=("left", "right"), maxdepth=8, limit=20,
               mode=:semantic, all=false)

Print what differs between two objects. The identical branches are left out —
pass `all=true` to keep them — so the output is the difference and not the
object.

Rows are marked `·` identical, `~` changed, `+` added on the right, `-`
removed, `!` unrelated types, in green when the two sides match and red when
they do not.

```julia
julia> print_diff(before, after; names=("before", "after"))
before ⇄ after::Run
├─ ~ name::String "exp-042" → "exp-043"
└─ ~ losses::Vector{Float64}
   ├─ ~ [2]::Float64 1.87 → 1.8
   └─ + [4]::Float64 1.02
```
"""
function print_diff(
    io::IO,
    @nospecialize(x),
    @nospecialize(y);
    names::Tuple{AbstractString,AbstractString} = ("left", "right"),
    maxdepth::Int = 8,
    limit::Int = 20,
    mode = Semantic(),
    all::Bool = false,
)
    lname, rname = String(names[1]), String(names[2])
    root = root_node(Diff(x, y), lname; limit, mode = exploration_mode(mode))
    root.key = "$lname ⇄ $rname"

    if node_status(root) === :same && !all
        printstyled(io, "The two objects are identical.\n"; color = _ansi(tstyle(:success)))
        return nothing
    end

    tree = all ? root : Differing(root)
    AbstractTrees.print_tree(io, tree; maxdepth)
    nothing
end

print_diff(@nospecialize(x), @nospecialize(y); kwargs...) =
    print_diff(stdout, x, y; kwargs...)
