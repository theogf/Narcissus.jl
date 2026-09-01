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
    hide_same::Bool
    show_memory::Bool
    kinds::Symbol
    pending::Vector{Tuple{ObjNode,Symbol}}
    last_area::Rect
    # Frames drawn, which is all the clock a spinner needs.
    tick::Int
    # Set once a value proves slow to print: from then on the frame renders no
    # value itself. One such value is reason enough — a tree tends to hold more
    # of the same kind, and each would otherwise cost another frame.
    slow_previews::Bool
    _rows::Vector{Row}
    _dirty::Bool
end

function ObjectTree(root::ObjNode; selected::Int = 1, focused::Bool = true, indent::Int = 2)
    ObjectTree(
        root,
        selected,
        0,
        focused,
        indent,
        "",
        false,
        false,
        :all,
        Tuple{ObjNode,Symbol}[],
        Rect(),
        0,
        false,
        Row[],
        true,
    )
end

function rows(t::ObjectTree)
    if t._dirty
        t._rows = flatten(t.root; hide_same = t.hide_same, kinds = t.kinds)
        t._dirty = false
    end
    t._rows
end

invalidate!(t::ObjectTree) = (t._dirty = true; nothing)

"""
    request!(tree, node, kind)

Note that `node` needs `kind` (`:bytes` or `:anomaly`) worked out, without
working it out here.

Rendering a frame must stay proportional to the screen. Scanning an array for
`NaN`s, or walking an object to size it, is proportional to the *data*, so the
renderer records what it wants and the model computes it off the main task —
see `Narcissus.dispatch_work!`.
"""
request!(t::ObjectTree, n::ObjNode, kind::Symbol) = (push!(t.pending, (n, kind)); nothing)

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

"""
    node_text_cheap(node) -> String

What a row says, without paying for it.

[`node_text`](@ref) renders the value, which means a `show` call — fine for the
rows on screen, ruinous for a deep walk that visits thousands of nodes it will
throw away. This matches on the key and the type, plus the value only when some
earlier render already cached it.
"""
function node_text_cheap(n::ObjNode)
    s = n.key
    ty = type_string(n)
    isempty(ty) || (s *= "::" * ty)
    n._preview === nothing || (s *= " = " * n._preview)
    s
end

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
            node.value isa Diff ? expand_differences!(node, 8) : expand_recursive!(node, 2)
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
    cycle_kinds!(tree) -> Symbol

Step a module listing through `all → functions → types → modules → values`.

A package's exported names are a jumble of four different things, and you are
usually after one of them. Only rows directly under a module node are filtered
— see [`flatten`](@ref).
"""
function cycle_kinds!(t::ObjectTree)
    i = something(findfirst(==(t.kinds), BINDING_KINDS), 1)
    t.kinds = BINDING_KINDS[mod1(i + 1, length(BINDING_KINDS))]
    invalidate!(t)
    clamp_selection!(t)
    t.kinds
end

"Whether the cursor is on, or inside, a module listing."
function in_module(t::ObjectTree)
    n = current_node(t)
    while n !== nothing
        n.value isa Module && return true
        n = n.parent
    end
    false
end

"""
    toggle_memory!(tree)

Swap the value column for what each row *costs*: its retained size, its share
of its parent, and a bar to eyeball where the bytes went.

Sizes come from `Base.summarysize`, which walks the whole retained graph — so
this is a key you press rather than a column that is always there, and the
answer is cached per node once asked.
"""
function toggle_memory!(t::ObjectTree)
    t.show_memory = !t.show_memory
    t.show_memory
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
    n.value isa Module && forget_modules!()
    refresh_value!(n)
    n._preview = nothing
    n._type = nothing
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

# ── Search and jumps ─────────────────────────────────────────────────

"Move the cursor to the next visible row satisfying `predicate`, wrapping."
function jump!(predicate, t::ObjectTree, dir::Int, from::Int)
    r = rows(t)
    n = length(r)
    n == 0 && return false
    for step = 1:n
        idx = mod1(from + dir * step, n)
        if predicate(r[idx].node)
            t.selected = idx
            return true
        end
    end
    false
end

"""
    search!(tree, query, dir; from=tree.selected, deep=true) -> Symbol

Find `query`, returning `:visible` when a row already on screen matched,
`:revealed` when the tree had to open the object up to find it, or `:none`.

**Names before values.** A parent's preview contains the text of everything
under it, so matching rendered values first would answer "where is `sigma`?"
with the root row — technically a match, never the one you meant. Keys and
types are tried first, on screen and then in the unread object; only when
nothing is named that way does the value text of the visible rows count.

The deep walk also matches the values of *leaf* rows, which are cheap to
render. It will not render a container's preview to search it — that is the
expense the lazy tree exists to avoid.
"""
function search!(
    t::ObjectTree,
    query::AbstractString,
    dir::Int = 1;
    from::Int = t.selected,
    deep::Bool = true,
)
    isempty(query) && return :none
    needle = lowercase(query)

    named(n) =
        occursin(needle, lowercase(n.key)) || occursin(needle, lowercase(type_string(n)))
    deep_match(n) = named(n) || (!n.expandable && occursin(needle, lowercase(preview(n))))

    jump!(named, t, dir, from) && return :visible

    if deep
        found = find_node(t.root, deep_match)
        if found !== nothing
            reveal!(found)
            invalidate!(t)
            select_node!(t, found)
            return :revealed
        end
    end

    # Last resort: the rendered value of something already on screen.
    jump!(n -> occursin(needle, lowercase(node_text(n))), t, dir, from) && return :visible
    :none
end

"""
    hunt_anomaly!(tree, dir; from=tree.selected) -> Symbol

The [`anomaly`](@ref) counterpart of [`search!`](@ref), with the same
escalation: find the next `NaN`, `Inf`, `missing`, empty container, `#undef` or
unreadable value, on screen if possible and in the unread object if not.
"""
function hunt_anomaly!(t::ObjectTree, dir::Int = 1; from::Int = t.selected)
    here = current_node(t)
    # Excluding the row already under the cursor is what lets a second press
    # escalate: wrapping onto itself would otherwise look like a match.
    suspicious(n) = n !== here && node_anomaly(n) !== nothing

    jump!(suspicious, t, dir, from) && return :visible

    found = find_node(t.root, suspicious)
    found === nothing && return :none
    reveal!(found)
    invalidate!(t)
    select_node!(t, found)
    :revealed
end

"""
    next_difference!(tree, dir; from=tree.selected) -> Bool

Move the cursor to the next visible row that is not identical on both sides.
Unlike [`search!`](@ref) this does not escalate: the branches that differ were
opened when the comparison did, and the ones still closed matched.
"""
next_difference!(t::ObjectTree, dir::Int = 1; from::Int = t.selected) =
    jump!(n -> is_difference(node_status(n)), t, dir, from)

"Whether this tree is comparing two objects rather than exploring one."
comparing(t::ObjectTree) = t.root.value isa Diff

"""
    difference_counts(tree) -> NamedTuple

How many changed, added, removed and type-mismatched rows are on screen. A
tally of what is visible, which grows as branches are opened — not a claim
about the whole object, which would mean reading all of it.
"""
function difference_counts(t::ObjectTree)
    changed = added = removed = mistyped = 0
    for r in rows(t)
        st = node_status(r.node)
        st === :changed && (changed += 1)
        st === :added && (added += 1)
        st === :removed && (removed += 1)
        st === :type && (mistyped += 1)
    end
    (; changed, added, removed, mistyped)
end

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
    n.kind === :root && return tstyle(:title, bold = true)
    n.kind === :field && return tstyle(:primary, bold = true)
    n.kind === :index && return tstyle(:accent)
    n.kind === :key && return tstyle(:warning)
    n.kind === :cycle && return tstyle(:error, bold = true)
    n.kind === :elided && return tstyle(:text_dim, italic = true)
    tstyle(:text)
end

"""
    PREVIEW_BUDGET_NS

How long a frame may spend rendering values before it hands the rest over.

A frame has about sixteen milliseconds. Nearly every `show` costs microseconds
and is done inline; the budget is what stops a row whose value takes a
noticeable time to print from taking the whole frame with it, and every row
after it. Those rows spin instead, and are rendered off the main task.
"""
const PREVIEW_BUDGET_NS = 5_000_000

function Tachikoma.render(t::ObjectTree, rect::Rect, buf::Buffer)
    # One tick per frame drawn: enough of a clock to turn a spinner with, and
    # deterministic, which a wall clock would not be.
    t.tick += 1
    deadline = time_ns() + PREVIEW_BUDGET_NS
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

    # The flag column is only worth its two cells when something can appear in
    # it. Decided once per frame so every row indents alike.
    flag_col =
        comparing(t) || any(
            i -> let idx = t.offset + i
                idx <= n && !(anomaly_state(r[idx].node) in (:pending, :none))
            end,
            1:visible,
        )

    needs_sb = n > visible
    text_area =
        needs_sb && rect.width > 1 ? Rect(rect.x, rect.y, rect.width - 1, rect.height) :
        rect
    max_x = right(text_area)
    conn = tstyle(:border, dim = true)

    # The memory column is right-aligned to the pane, so sizes and percentages
    # line up down the screen. Everything else gets the width that is left.
    mem_x = max_x - MEMORY_COLUMN_WIDTH + 1
    text_max_x = t.show_memory ? mem_x - 2 : max_x

    for i = 1:visible
        idx = t.offset + i
        idx > n && break
        row = r[idx]
        node = row.node
        y = text_area.y + i - 1
        selected = idx == t.selected

        cx = text_area.x
        if selected
            set_char!(
                buf,
                cx,
                y,
                '▌',
                t.focused ? tstyle(:accent, bold = true) : tstyle(:text_dim),
            )
        end
        cx += 2

        # Connectors from the ancestry.
        if row.depth > 0
            # Bit k of `lasts` is the "is last child" answer for the ancestor
            # at depth k-1, so the guide line for indent slot d comes from d+1:
            # a line continues past this row only where that ancestor had
            # siblings still to come.
            for d = 1:(row.depth-1)
                if cx <= max_x && !last_at(row.lasts, d + 1)
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

        # One column, two purposes: in a comparison it carries the diff status,
        # and otherwise it flags a value worth looking at twice. Both stay blank
        # when there is nothing to say, so an ordinary tree gains no clutter.
        if flag_col
            status = node_status(node)
            glyph, gstyle = if status !== :none
                status_marker(status)
            else
                flag = anomaly_state(node)
                flag === :pending && request!(t, node, :anomaly)
                anomaly_marker(flag in (:pending, :none) ? nothing : flag)
            end
            glyph == ' ' || set_char!(buf, cx, y, glyph, gstyle)
            cx += 2
            cx > max_x && continue
        else
            anomaly_state(node) === :pending && request!(t, node, :anomaly)
        end

        # `node_text_cheap`, so highlighting a match never renders a value the
        # row has not rendered yet — it will match on the next frame, once the
        # preview has arrived.
        matched =
            !isempty(t.query) &&
            occursin(lowercase(t.query), lowercase(node_text_cheap(node)))
        kstyle = matched ? tstyle(:warning, bold = true, underline = true) : key_style(node)
        cx = set_string!(buf, cx, y, node.key, kstyle; max_x = text_max_x)

        ty = type_string(node)
        if !isempty(ty) && cx <= text_max_x
            cx = set_string!(buf, cx, y, "::", conn; max_x = text_max_x)
            type_style = node_status(node) === :type ? tstyle(:error) : tstyle(:secondary)
            width_for_type = t.show_memory ? text_max_x - cx + 1 : max(8, (max_x - cx) ÷ 2)
            cx = set_string!(
                buf,
                cx,
                y,
                truncate_text(ty, width_for_type),
                type_style;
                max_x = text_max_x,
            )
        end

        # Only worth saying when the row is showing storage instead of meaning.
        if node.mode isa Fields && has_semantic_view(node.value) && cx <= max_x
            cx = set_string!(buf, cx, y, " ·fields", tstyle(:warning, dim = true); max_x)
        end

        if t.show_memory
            cm = mem_x
            for (text, style) in memory_spans(node, t)
                cm = set_string!(buf, cm, y, text, style; max_x)
            end
            continue
        end

        segments = if node._preview !== nothing
            preview_spans(node, selected)
        elseif !t.slow_previews && time_ns() < deadline
            # Cheap previews — which is nearly all of them — are still rendered
            # right here, so an ordinary object never flickers through a screen
            # of spinners on its way to being drawn. The first one that is not
            # cheap ends that for this tree: the budget can decline to *start*
            # a render, but nothing can cut one short once it has.
            started = time_ns()
            preview(node)
            time_ns() - started > SLOW_RENDER_NS && (t.slow_previews = true)
            preview_spans(node, selected)
        else
            request!(t, node, :preview)
            pending_spans(t.tick)
        end
        if !isempty(segments) && cx + 3 <= max_x
            cx = set_string!(buf, cx, y, " = ", conn; max_x)
            for (text, style) in segments
                cx > max_x && break
                cx = set_string!(
                    buf,
                    cx,
                    y,
                    truncate_text(text, max_x - cx + 1),
                    style;
                    max_x,
                )
            end
        end
    end

    if needs_sb && rect.width > 1
        render(
            Scrollbar(n, visible, t.offset),
            Rect(right(rect), rect.y, 1, rect.height),
            buf,
        )
    end
    nothing
end
