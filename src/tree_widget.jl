# ═══════════════════════════════════════════════════════════════════════
# ObjectTree ── the left pane: a lazily expanded, styled object tree
# ═══════════════════════════════════════════════════════════════════════

"""
    ObjectTree(root)

Tachikoma widget rendering an [`ObjNode`](@ref) tree. Unlike a plain
`TreeView` it colours each part of a row separately — key, type, value — and
pulls children in only as nodes are opened.
"""
mutable struct ObjectTree
    root::ObjNode
    selected::Int
    offset::Int
    focused::Bool
    indent::Int
    query::String
    last_area::Rect
    _rows::Vector{Row}
    _dirty::Bool
end

function ObjectTree(root::ObjNode; selected::Int=1, focused::Bool=true, indent::Int=2)
    ObjectTree(root, selected, 0, focused, indent, "", Rect(), Row[], true)
end

function rows(t::ObjectTree)
    if t._dirty
        t._rows = flatten(t.root)
        t._dirty = false
    end
    t._rows
end

invalidate!(t::ObjectTree) = (t._dirty = true; nothing)

"The node under the cursor, or `nothing` when the tree is empty."
function current_node(t::ObjectTree)
    r = rows(t)
    (t.selected < 1 || t.selected > length(r)) && return nothing
    r[t.selected].node
end

"Move the cursor to `node` if it is currently visible."
function select_node!(t::ObjectTree, n::ObjNode)
    for (i, r) in enumerate(rows(t))
        r.node === n && (t.selected = i; return true)
    end
    false
end

Tachikoma.focusable(::ObjectTree) = true
Tachikoma.value(t::ObjectTree) = current_node(t)

"Flat text of a row, used for searching."
function node_text(n::ObjNode)
    ty = type_string(n)
    pv = preview(n)
    s = n.key
    isempty(ty) || (s *= "::" * ty)
    isempty(pv) || (s *= " = " * pv)
    s
end

# ── Key handling ─────────────────────────────────────────────────────

function Tachikoma.handle_key!(t::ObjectTree, e::KeyEvent)::Bool
    r = rows(t)
    n = length(r)
    n == 0 && return false
    page = max(1, t.last_area.height - 1)

    if e.key == :up || (e.key == :char && e.char == 'k')
        t.selected = t.selected > 1 ? t.selected - 1 : n
    elseif e.key == :down || (e.key == :char && e.char == 'j')
        t.selected = t.selected < n ? t.selected + 1 : 1
    elseif e.key == :home || (e.key == :char && e.char == 'g')
        t.selected = 1
    elseif e.key == :end_key || (e.key == :char && e.char == 'G')
        t.selected = n
    elseif e.key == :pageup
        t.selected = max(1, t.selected - page)
    elseif e.key == :pagedown
        t.selected = min(n, t.selected + page)
    elseif e.key == :left || (e.key == :char && e.char == 'h')
        collapse_or_parent!(t)
    elseif e.key == :right || (e.key == :char && e.char == 'l')
        expand_or_child!(t)
    elseif e.key == :enter || (e.key == :char && e.char == ' ')
        node = current_node(t)
        node !== nothing && toggle!(node) && invalidate!(t)
    elseif e.key == :char && e.char == 'e'
        node = current_node(t)
        if node !== nothing
            # In a comparison, "expand" means "show me what differs".
            node.value isa Diff ? expand_differences!(node, 8) :
                                  expand_recursive!(node, 2)
            invalidate!(t)
        end
    elseif e.key == :char && e.char == 'c'
        node = current_node(t)
        if node !== nothing
            collapse_recursive!(node)
            invalidate!(t)
            select_node!(t, node)
        end
    else
        return false
    end
    clamp_selection!(t)
    true
end

function collapse_or_parent!(t::ObjectTree)
    row = rows(t)[t.selected]
    node = row.node
    if node.expanded
        node.expanded = false
        invalidate!(t)
    elseif node.parent !== nothing
        invalidate!(t)
        select_node!(t, node.parent)
    end
    nothing
end

function expand_or_child!(t::ObjectTree)
    node = current_node(t)
    node === nothing && return nothing
    if node.kind === :elided
        expand_elided!(node)
        invalidate!(t)
    elseif node.expandable && !node.expanded
        toggle!(node)
        invalidate!(t)
    elseif node.expanded && !isempty(node.children)
        t.selected += 1
    end
    nothing
end

function clamp_selection!(t::ObjectTree)
    n = length(rows(t))
    t.selected = n == 0 ? 0 : clamp(t.selected, 1, n)
    nothing
end

"""
    switch_mode!(tree) -> Bool

Flip the node under the cursor between its semantic and field views. A no-op
on values with only one view — see [`has_semantic_view`](@ref).
"""
function switch_mode!(t::ObjectTree)
    n = current_node(t)
    n === nothing && return false
    toggle_mode!(n) || return false
    n._status = nothing
    invalidate!(t)
    clamp_selection!(t)
    true
end

"""
    reload!(tree) -> Bool

Re-read the node under the cursor: its cached preview, its child count and,
if it was open, its children. Use it when the object is being mutated
underneath the explorer — from a debugger prompt, or another task.

The subtree below the reloaded node collapses, since its children are new
objects.
"""
function reload!(t::ObjectTree)
    n = current_node(t)
    n === nothing && return false
    refresh_value!(n)
    n._preview = nothing
    n._status = nothing
    n.total = n_components(n.mode, n.value)
    n.expandable = expandable(n.mode, n.value)
    if n.loaded
        n.loaded = false
        n.children = ObjNode[]
        load_children!(n)
        n.expanded = n.expanded && n.expandable
    end
    invalidate!(t)
    clamp_selection!(t)
    true
end

# ── Search ───────────────────────────────────────────────────────────

"""
    search!(tree, query, dir; from=tree.selected) -> Bool

Move the cursor to the next row (in direction `dir`, `+1` or `-1`) whose text
matches `query`, wrapping around. Only *visible* rows are searched — the tree
is lazy, and matching against unloaded children would mean walking the whole
object graph.
"""
function search!(t::ObjectTree, query::AbstractString, dir::Int=1;
                 from::Int=t.selected)
    isempty(query) && return false
    r = rows(t)
    n = length(r)
    n == 0 && return false
    needle = lowercase(query)
    for step in 1:n
        idx = mod1(from + dir * step, n)
        if occursin(needle, lowercase(node_text(r[idx].node)))
            t.selected = idx
            return true
        end
    end
    false
end

"""
    next_difference!(tree, dir; from=tree.selected) -> Bool

Move the cursor to the next visible row (in direction `dir`) that is not
identical on both sides, wrapping around. The comparison counterpart of
[`search!`](@ref), and visible-rows-only for the same reason.
"""
function next_difference!(t::ObjectTree, dir::Int=1; from::Int=t.selected)
    r = rows(t)
    n = length(r)
    n == 0 && return false
    for step in 1:n
        idx = mod1(from + dir * step, n)
        if is_difference(node_status(r[idx].node))
            t.selected = idx
            return true
        end
    end
    false
end

"Whether this tree is comparing two objects rather than exploring one."
comparing(t::ObjectTree) = t.root.value isa Diff

# ── Mouse ────────────────────────────────────────────────────────────

function Tachikoma.handle_mouse!(t::ObjectTree, e::MouseEvent)::Bool
    t.last_area.width == 0 && return false
    Base.contains(t.last_area, e.x, e.y) || return false
    r = rows(t)
    n = length(r)

    hit = list_hit(e, t.last_area, t.offset, n)
    if hit > 0
        if hit == t.selected
            node = r[hit].node
            toggle!(node) && invalidate!(t)
            clamp_selection!(t)
        else
            t.selected = hit
        end
        return true
    end
    new_offset = list_scroll(e, t.offset, n, max(1, t.last_area.height))
    new_offset == t.offset && return false
    t.offset = new_offset
    true
end

# ── Rendering ────────────────────────────────────────────────────────

function key_style(n::ObjNode)
    # In a comparison, what matched is context; what changed is the point.
    node_status(n) === :same && return tstyle(:text_dim)
    n.kind === :root   && return tstyle(:title, bold=true)
    n.kind === :field  && return tstyle(:primary, bold=true)
    n.kind === :index  && return tstyle(:accent)
    n.kind === :key    && return tstyle(:warning)
    n.kind === :cycle  && return tstyle(:error, bold=true)
    n.kind === :elided && return tstyle(:text_dim, italic=true)
    tstyle(:text)
end

function Tachikoma.render(t::ObjectTree, rect::Rect, buf::Buffer)
    (rect.width < 4 || rect.height < 1) && return
    t.last_area = rect

    r = rows(t)
    n = length(r)
    visible = rect.height

    # Keep the cursor on screen.
    if t.selected >= 1
        if t.selected - 1 < t.offset
            t.offset = t.selected - 1
        elseif t.selected > t.offset + visible
            t.offset = t.selected - visible
        end
    end
    t.offset = clamp(t.offset, 0, max(0, n - visible))

    needs_sb = n > visible
    text_area = needs_sb && rect.width > 1 ?
        Rect(rect.x, rect.y, rect.width - 1, rect.height) : rect
    max_x = right(text_area)
    conn = tstyle(:border, dim=true)

    for i in 1:visible
        idx = t.offset + i
        idx > n && break
        row = r[idx]
        node = row.node
        y = text_area.y + i - 1
        selected = idx == t.selected

        cx = text_area.x
        if selected
            set_char!(buf, cx, y, '▌',
                      t.focused ? tstyle(:accent, bold=true) : tstyle(:text_dim))
        end
        cx += 2

        # Connectors from the ancestry.
        if row.depth > 0
            # `parent_lasts[k]` is the "is last child" flag of the ancestor at
            # depth k-1, so the guide line for indent slot d comes from d+1.
            for d in 1:(row.depth - 1)
                if cx <= max_x && d + 1 <= length(row.parent_lasts) &&
                   !row.parent_lasts[d + 1]
                    set_char!(buf, cx, y, '│', conn)
                end
                cx += t.indent
            end
            cx <= max_x && set_char!(buf, cx, y, row.is_last ? '└' : '├', conn)
            cx += 1
            cx <= max_x && set_char!(buf, cx, y, '─', conn)
            cx += 1
        end

        # Expansion marker.
        if node.expandable
            set_char!(buf, cx, y, node.expanded ? '▾' : '▸', tstyle(:text_dim))
        end
        cx += 1
        cx > max_x && continue

        # Comparison status. Absent (and costing nothing) outside a diff tree.
        status = node_status(node)
        if status !== :none
            glyph, gstyle = status_marker(status)
            set_char!(buf, cx, y, glyph, gstyle)
            cx += 2
            cx > max_x && continue
        end

        matched = !isempty(t.query) &&
                  occursin(lowercase(t.query), lowercase(node_text(node)))
        kstyle = matched ? tstyle(:warning, bold=true, underline=true) : key_style(node)
        cx = set_string!(buf, cx, y, node.key, kstyle; max_x)

        ty = type_string(node)
        if !isempty(ty) && cx <= max_x
            cx = set_string!(buf, cx, y, "::", conn; max_x)
            cx = set_string!(buf, cx, y, truncate_text(ty, max(8, (max_x - cx) ÷ 2)),
                             tstyle(:secondary); max_x)
        end

        # Only worth saying when the row is showing storage instead of meaning.
        if node.mode isa Fields && has_semantic_view(node.value) && cx <= max_x
            cx = set_string!(buf, cx, y, " ·fields", tstyle(:warning, dim=true); max_x)
        end

        segments = preview_spans(node, selected)
        if !isempty(segments) && cx + 3 <= max_x
            cx = set_string!(buf, cx, y, " = ", conn; max_x)
            for (text, style) in segments
                cx > max_x && break
                cx = set_string!(buf, cx, y, truncate_text(text, max_x - cx + 1),
                                 style; max_x)
            end
        end
    end

    if needs_sb && rect.width > 1
        render(Scrollbar(n, visible, t.offset),
               Rect(right(rect), rect.y, 1, rect.height), buf)
    end
    nothing
end
