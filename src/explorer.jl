# ═══════════════════════════════════════════════════════════════════════
# Explorer ── the Tachikoma app: tree on the left, detail on the right
# ═══════════════════════════════════════════════════════════════════════

const HELP_TEXT = """
  ↑ k / ↓ j        move                /        search visible rows
  PgUp / PgDn      page                n / N    next / previous match
  g / G            first / last row    Esc      clear the search

  → l              expand, or step into the first child
  ← h              collapse, or jump to the parent
  Enter / Space    toggle the row under the cursor
  e / c            expand two levels / collapse the whole subtree

  m                switch between the semantic and field views of a value
                   (a Dict as entries, or as slots/keys/vals/count/…)

  Tab              move focus between the tree and the detail pane
  drag             the border between the panes resizes them; right-click
                   it to restore the default split
  y / Y            copy the path expression / the printed value
  r                re-read the selected node from the live object
  ? / q            this help / quit, returning the selected value

  Find
    a / A            jump to the next / previous NaN, Inf, missing, empty
                     container, #undef or unreadable value
    f                inside a module, list only functions / types / modules
                     / values in turn
    M                show what each row costs in memory instead of its value

  Comparing (narcissus(x, y))
    · green          the two sides are identical
    ~ + - ! red      changed, added on the right, removed, unrelated types
    d / D            jump to the next / previous difference
    f                hide the branches that matched
    e                open every differing branch under the cursor

  Long containers arrive one window at a time — open the `…` row at the
  end of a list to pull in the next batch. Searching looks at what is on
  screen first, then opens the object up to keep looking.
"""

Base.@kwdef mutable struct Explorer <: Model
    tree::ObjectTree
    detail::Vector{Vector{Tuple{String,Style}}} = Vector{Tuple{String,Style}}[]
    detail_key::Tuple{UInt,Int,Int} = (UInt(0), 0, 0)
    detail_budget::Int = 0
    detail_offset::Int = 0
    revision::Int = 0
    focus::Symbol = :tree
    quit::Bool = false
    show_help::Bool = false
    searching::Bool = false
    input::TextInput = TextInput(; label="/ ", focused=true)
    notice::String = ""
    notice_ttl::Int = 0
    names::Union{Nothing,Tuple{String,String}} = nothing
    work::TaskQueue = TaskQueue()
    # Keyed by node *and* kind: a node can want both its size and its anomaly,
    # and tracking only the node would silently drop the second request.
    in_flight::Set{Tuple{ObjNode,Symbol}} = Set{Tuple{ObjNode,Symbol}}()
    # Draggable split between the two panes. A comparison wants a wide tree
    # (two values per row); exploring one object wants a wide detail pane.
    split::ResizableLayout = ResizableLayout(Horizontal,
                                             Constraint[Percent(55), Fill(1)];
                                             min_pane_size=12)
end

"Whether this explorer is comparing two objects rather than exploring one."
comparing(m::Explorer) = comparing(m.tree)

should_quit(m::Explorer) = m.quit

# Handing the queue to the app loop is what makes it drain finished work each
# frame and deliver it back here as a `TaskEvent`.
task_queue(m::Explorer) = m.work

"How many measurements may be in flight at once."
const MAX_IN_FLIGHT = 4

"""
    dispatch_work!(m)

Hand whatever the last frame asked for to background tasks.

Scanning an array for `NaN`s or walking an object to size it takes time
proportional to the data, and a frame must take time proportional to the
screen. The renderer records what it wants (`Narcissus.request!`) and this
spawns it, capped at [`MAX_IN_FLIGHT`](@ref) so that opening a wide row does
not start a hundred walks at once. Results arrive as `TaskEvent`s.

`Threads.@spawn` does the work, so it genuinely overlaps only when Julia was
started with more than one thread; on a single thread it still moves the cost
out from between the layout and the paint.
"""
function dispatch_work!(m::Explorer)
    isempty(m.tree.pending) && return nothing
    for request in m.tree.pending
        length(m.in_flight) >= MAX_IN_FLIGHT && break
        request in m.in_flight && continue
        push!(m.in_flight, request)
        node, kind = request
        spawn_task!(m.work, :measure) do
            (node, kind, measure(kind, node))
        end
    end
    empty!(m.tree.pending)
    nothing
end

"Compute one requested value. Runs off the main task, and touches no state."
function measure(kind::Symbol, node::ObjNode)
    kind === :bytes && return bounded_size(node_measurand(node))
    kind === :anomaly && return node.value isa Diff ? nothing : anomaly(node.value)
    nothing
end

"""
    update!(m::Explorer, e::TaskEvent)

Take delivery of a background measurement. Writing the result here, on the main
task, is what keeps it out of a data race with the walk that produced it.
"""
function update!(m::Explorer, e::TaskEvent)
    e.value isa Tuple{ObjNode,Symbol,Any} || return nothing
    node, kind, result = e.value
    delete!(m.in_flight, (node, kind))
    if kind === :bytes && result isa Tuple{Int,Bool}
        set_bytes!(node, result)
    elseif kind === :anomaly
        set_anomaly!(node, result isa Symbol ? result : nothing)
        # An anomaly can bring the flag column into existence.
        invalidate!(m.tree)
    end
    m.revision += 1
    nothing
end

"The value currently under the cursor — what `narcissus` hands back on exit."
function selected_value(m::Explorer)
    n = current_node(m.tree)
    n === nothing ? nothing : n.value
end

function notify!(m::Explorer, msg::AbstractString)
    m.notice = String(msg)
    m.notice_ttl = 120
    nothing
end

# ── Update ───────────────────────────────────────────────────────────

function update!(m::Explorer, e::KeyEvent)
    e.action === key_release && return nothing

    if m.show_help
        (e.key == :escape || e.key == :char || e.key == :enter) && (m.show_help = false)
        return nothing
    end

    m.searching && return search_key!(m, e)

    if e.key == :ctrl_c || (e.key == :char && e.char == 'q')
        m.quit = true
    elseif e.key == :escape
        if isempty(m.tree.query)
            m.quit = true
        else
            m.tree.query = ""
            notify!(m, "search cleared")
        end
    elseif e.key == :char && e.char == '?'
        m.show_help = true
    elseif e.key == :tab || e.key == :backtab
        m.focus = m.focus === :tree ? :detail : :tree
        m.tree.focused = m.focus === :tree
    elseif e.key == :char && e.char == '/'
        m.searching = true
        set_text!(m.input, m.tree.query)
        m.input.focused = true
    elseif e.key == :char && (e.char == 'n' || e.char == 'N')
        if isempty(m.tree.query)
            notify!(m, "no search query — press / first")
        else
            outcome = search!(m.tree, m.tree.query, e.char == 'n' ? 1 : -1)
            m.revision += 1
            outcome === :none && notify!(m, "no match for \"$(m.tree.query)\"")
            outcome === :revealed &&
                notify!(m, "found in $(current_node(m.tree).path)")
        end
    elseif e.key == :char && (e.char == 'a' || e.char == 'A')
        outcome = hunt_anomaly!(m.tree, e.char == 'a' ? 1 : -1)
        m.revision += 1
        if outcome === :none
            notify!(m, "nothing suspicious found")
        elseif outcome === :revealed
            notify!(m, "opened $(current_node(m.tree).path)")
        end
    elseif e.key == :char && e.char == 'M'
        notify!(m, toggle_memory!(m.tree) ? "showing retained size" :
                                            "showing values")
    elseif e.key == :char && e.char == 'f'
        # One key, one meaning — "narrow this view" — and two things worth
        # narrowing: a comparison, and a module's jumble of bindings.
        if comparing(m)
            m.tree.hide_same = !m.tree.hide_same
            invalidate!(m.tree)
            clamp_selection!(m.tree)
            notify!(m, m.tree.hide_same ? "hiding what matched" : "showing everything")
        elseif in_module(m.tree)
            notify!(m, "showing $(kind_label(cycle_kinds!(m.tree)))")
        else
            notify!(m, "nothing to filter here")
        end
    elseif e.key == :char && (e.char == 'd' || e.char == 'D')
        if !comparing(m)
            notify!(m, "not comparing — open with narcissus(x, y)")
        elseif !next_difference!(m.tree, e.char == 'd' ? 1 : -1)
            notify!(m, "no other differences on screen")
        end
    elseif e.key == :char && e.char == 'm'
        node = current_node(m.tree)
        if switch_mode!(m.tree)
            m.revision += 1
            notify!(m, "$(node.key): $(mode_name(node.mode)) view")
        elseif node !== nothing
            notify!(m, "$(node.key) has only one view")
        end
    elseif e.key == :char && e.char == 'r'
        if reload!(m.tree)
            m.revision += 1               # force the detail pane to rebuild
            notify!(m, "reloaded")
        end
    elseif e.key == :char && (e.char == 'y' || e.char == 'Y')
        node = current_node(m.tree)
        if node !== nothing
            what = e.char == 'y' ? node.path : plain_show(node.value; width=100)
            label = e.char == 'y' ? node.path : "value of $(node.path)"
            notify!(m, copy_to_clipboard(what) ? "copied $label" : clipboard_hint())
        end
    elseif m.focus === :detail
        scroll_detail!(m, e)
    else
        handle_key!(m.tree, e)
    end
    nothing
end

function scroll_detail!(m::Explorer, e::KeyEvent)
    limit = max(0, length(m.detail) - 1)
    if e.key == :up || (e.key == :char && e.char == 'k')
        m.detail_offset = max(0, m.detail_offset - 1)
    elseif e.key == :down || (e.key == :char && e.char == 'j')
        m.detail_offset = min(limit, m.detail_offset + 1)
    elseif e.key == :pageup
        m.detail_offset = max(0, m.detail_offset - 10)
    elseif e.key == :pagedown
        m.detail_offset = min(limit, m.detail_offset + 10)
    elseif e.key == :home || (e.key == :char && e.char == 'g')
        m.detail_offset = 0
    end
    nothing
end

function search_key!(m::Explorer, e::KeyEvent)
    if e.key == :escape
        m.searching = false
        m.tree.query = ""
    elseif e.key == :enter
        m.searching = false
        m.tree.query = text(m.input)
        if !isempty(m.tree.query)
            # Enter is where the search is allowed to go looking in the parts of
            # the object nobody has opened yet; typing stays instant.
            outcome = search!(m.tree, m.tree.query, 1; from = m.tree.selected - 1)
            m.revision += 1
            outcome === :none && notify!(m, "no match for \"$(m.tree.query)\"")
            outcome === :revealed &&
                notify!(m, "found in $(current_node(m.tree).path)")
        end
    else
        handle_key!(m.input, e)
        m.tree.query = text(m.input)
        # Incremental: re-run from just before the cursor so the current row
        # stays put while it still matches.
        isempty(m.tree.query) ||
            search!(m.tree, m.tree.query, 1; from = m.tree.selected - 1, deep=false)
    end
    nothing
end

function update!(m::Explorer, e::MouseEvent)
    # The border between the panes is draggable; right-clicking it restores the
    # default split. Only events it does not claim reach the tree.
    handle_resize!(m.split, e) && return nothing
    if handle_mouse!(m.tree, e)
        m.focus = :tree
        m.tree.focused = true
    end
    nothing
end

# ── View ─────────────────────────────────────────────────────────────

"Extra lines rendered beyond the visible window, so a short scroll is free."
const DETAIL_LOOKAHEAD = 40

"""
    refresh_detail!(m, node, width, height)

Rebuild the detail pane, but only when it would say something different.

Rendering a value costs a `show` call, which for a large object is the most
expensive thing in the frame — so the pane is rebuilt when the selection, the
pane width or the object changes, and never merely because a frame was drawn.
The `show` is also sized to the window you can see plus [`DETAIL_LOOKAHEAD`](@ref)
lines; scrolling past that asks for a longer rendering, and only then.
"""
function refresh_detail!(m::Explorer, node::Union{Nothing,ObjNode},
                         width::Int, height::Int)
    key = (node === nothing ? UInt(0) : objectid(node), width, m.revision)
    if key != m.detail_key
        m.detail_key = key
        m.detail_budget = 0
        m.detail_offset = 0
    end

    needed = m.detail_offset + height + DETAIL_LOOKAHEAD
    needed > m.detail_budget || return nothing
    m.detail_budget = needed
    spans = node === nothing ? Span[] :
            detail_spans(node, width; names=m.names, height=needed)
    m.detail = wrap_spans(spans, max(1, width - 1))
    nothing
end

"""
    render_detail!(m, area, buffer)

Draw the rows of the (already wrapped) detail pane that fit, and a scrollbar if
there are more.
"""
function render_detail!(m::Explorer, area::Rect, buf::Buffer)
    (area.width < 1 || area.height < 1) && return nothing
    total = length(m.detail)
    m.detail_offset = clamp(m.detail_offset, 0, max(0, total - area.height))

    scrolling = total > area.height
    text_area = scrolling && area.width > 1 ?
        Rect(area.x, area.y, area.width - 1, area.height) : area
    max_x = right(text_area)

    for i in 1:area.height
        idx = m.detail_offset + i
        idx > total && break
        cx = text_area.x
        y = text_area.y + i - 1
        for (text, style) in m.detail[idx]
            cx > max_x && break
            cx = set_string!(buf, cx, y, text, style; max_x)
        end
    end

    scrolling && render(Scrollbar(total, area.height, m.detail_offset),
                        Rect(right(area), area.y, 1, area.height), buf)
    nothing
end

function view(m::Explorer, f::Frame)
    a = f.area
    (a.width < 8 || a.height < 4) && return nothing

    heights = m.searching ? Constraint[Fill(1), Fixed(1), Fixed(1)] :
                            Constraint[Fill(1), Fixed(1)]
    parts = split_layout(Layout(Vertical, heights), a)
    main, bar = parts[1], parts[end]

    cols = split_layout(m.split, main)

    node = current_node(m.tree)
    nrows = length(rows(m.tree))

    tree_block = Block(;
        title = comparing(m) ? " comparison " : " object ",
        title_right = comparing(m) ? diff_tally(m.tree) :
                      m.tree.kinds !== :all ? " $(kind_label(m.tree.kinds)) only " :
                      " $nrows row" * (nrows == 1 ? " " : "s "),
        border_style = tstyle(m.focus === :tree ? :border_focus : :border),
    )
    render(m.tree, render(tree_block, cols[1], f.buffer), f.buffer)

    detail_block = Block(;
        title = " detail ",
        title_right = node === nothing ? "" : " " * truncate_text(node.key, 24) * " ",
        border_style = tstyle(m.focus === :detail ? :border_focus : :border),
    )
    inner = render(detail_block, cols[2], f.buffer)
    refresh_detail!(m, node, inner.width, inner.height)
    render_detail!(m, inner, f.buffer)

    if m.searching
        render(m.input, parts[2], f.buffer)
    end
    render_resize_handles!(f.buffer, m.split)
    render(status_bar(m, bar.width), bar, f.buffer)
    m.show_help && render_help(f, a)

    dispatch_work!(m)
    m.notice_ttl > 0 && (m.notice_ttl -= 1)
    nothing
end

"A one-line tally of what differs on screen, for the pane's title bar."
function diff_tally(t::ObjectTree)
    c = difference_counts(t)
    parts = String[]
    c.changed > 0 && push!(parts, "~$(c.changed)")
    c.added > 0 && push!(parts, "+$(c.added)")
    c.removed > 0 && push!(parts, "-$(c.removed)")
    c.mistyped > 0 && push!(parts, "!$(c.mistyped)")
    isempty(parts) ? " identical " : " " * join(parts, " ") * " "
end

"""
    status_bar(m, width) -> StatusBar

The key hints, trimmed from the right until they fit alongside whatever the
right-hand side wants to say. A bar that overruns and collides with the path
is worse than one that shows five hints instead of nine.
"""
function status_bar(m::Explorer, width::Int)
    dim, key = tstyle(:text_dim), tstyle(:accent)

    right = Span[]
    if m.notice_ttl > 0 && !isempty(m.notice)
        push!(right, Span(truncate_text(m.notice, max(8, width ÷ 2)) * " ",
                          tstyle(:success)))
    else
        node = current_node(m.tree)
        node === nothing ||
            push!(right, Span(truncate_text(node.path, max(8, width ÷ 2)) * " ", dim))
    end
    budget = width - sum(textwidth(s.content) for s in right; init=0) - 1

    left = Span[]
    hints = comparing(m) ?
        [("↑↓", "move"), ("d", "next diff"), ("f", "fold same"), ("e", "expand"),
         ("/", "search"), ("m", "view"), ("y", "path"), ("?", "help"),
         ("q", "quit")] :
        [("↑↓", "move"), ("←→", "fold"), ("⏎", "toggle"), ("/", "search"),
         ("a", "anomaly"), ("M", "memory"), ("m", "view"), ("y", "path"),
         ("?", "help"), ("q", "quit")]
    # A module listing is a hundred names of four different kinds, and `f` is
    # the key that cuts it down — but only there, so it earns its place in the
    # bar only there. Third position, because hints are dropped from the right
    # and this one is the answer to what the screen is showing you.
    comparing(m) || !in_module(m.tree) ||
        insert!(hints, 3, ("f", m.tree.kinds === :all ? "filter" :
                                kind_label(m.tree.kinds)))
    for (k, label) in hints
        cost = textwidth(k) + textwidth(label) + 2
        cost > budget && break
        budget -= cost
        push!(left, Span(" " * k, key))
        push!(left, Span(" " * label, dim))
    end
    StatusBar(; left, right)
end

function render_help(f::Frame, a::Rect)
    lines = count('\n', HELP_TEXT) + 3
    rect = center(a, min(a.width - 4, 74), min(a.height - 2, lines))
    for y in rect.y:bottom(rect), x in rect.x:right(rect)
        set_char!(f.buffer, x, y, ' ', Style(; bg = theme().bg))
    end
    p = Paragraph(HELP_TEXT;
                  block = Block(; title = " keys ",
                                title_right = " any key closes ",
                                border_style = tstyle(:accent)),
                  wrap = no_wrap, style = tstyle(:text))
    render(p, rect, f.buffer)
    nothing
end

# ── Entry point ──────────────────────────────────────────────────────

"""
    warm!(model) -> model

Render one frame off-screen, before the terminal is handed over.

Everything expensive about the first frame happens here rather than behind the
alternate screen: the `show` method of a value nobody has printed before, the
preview of every row that will be visible, the detail pane. Both are cached on
the nodes, so the app does not pay for it twice.

The point is not the speed, it is the way out. Inside the app loop the terminal
is in raw mode, which makes `^C` a byte waiting to be read rather than a
signal — and a value whose `show` takes a minute is then a minute you cannot
interrupt, in front of a screen that has not drawn yet. Out here it is an
ordinary computation and `^C` is an ordinary interrupt.

Anything else that goes wrong is left for the app, which draws each row inside
its own error handling and will report it in place.
"""
function warm!(m::Explorer)
    try
        size = Tachikoma.terminal_size()
        rect = Rect(1, 1, max(20, size.cols), max(6, size.rows))
        view(m, Frame(Buffer(rect), rect, GraphicsRegion[], PixelSnapshot[]))
    catch e
        e isa InterruptException && rethrow()
    end
    m
end

"""
    narcissus(obj; name="obj", limit=$DEFAULT_LIMIT, expand=1, mode=:semantic, kwargs...)

Open a terminal UI that walks `obj` field by field, and return the value
sitting under the cursor when you quit.

The tree is built lazily: children are read only when a node is opened, cycles
are detected and marked rather than followed, and containers are materialised
`limit` elements at a time. That makes it safe to point at a recursive struct
or a huge array.

- `name` — how the root is labelled, and the prefix of every path expression
  shown in the detail pane (so `y` yields something you can paste into the REPL).
- `expand` — how many levels to open up front.
- `limit` — container elements pulled in per batch.
- `mode` — `:semantic` (a `Dict` as its entries) or `:fields` (a `Dict` as the
  struct fields Julia stores). Any node can be flipped with `m` while you look.
  See [`components`](@ref) to teach Narcissus about your own types.

Extra keyword arguments are forwarded to `Tachikoma.app`.

Press `?` inside the app for the full key list.

```julia
julia> narcissus(rand(3, 3))

julia> x = narcissus(model; name="model")   # `x` is the row you left the cursor on
```
"""
function narcissus(@nospecialize(obj); name::AbstractString="obj",
                   limit::Int=DEFAULT_LIMIT, expand::Int=1,
                   mode=Semantic(), kwargs...)
    root = root_node(obj, name; limit, mode=exploration_mode(mode))
    expand_recursive!(root, expand - 1)
    m = Explorer(; tree = ObjectTree(root))
    # A module opens onto a wall of names, and the key that cuts it down is the
    # one nobody thinks to look for. Say so once, on the way in.
    obj isa Module && notify!(m, "f filters this listing by kind")
    app(warm!(m); kwargs...)
    selected_value(m)
end

"""
    narcissus(x, y; names=("left", "right"), expand=8, mode=:semantic, kwargs...)

Compare two objects side by side and return the [`Diff`](@ref) under the cursor
when you quit.

The tree opens with the differing branches expanded and the identical ones
folded away, so the shape of the difference is the first thing you see. Each
row is marked `·` identical, `~` changed, `+` added on the right, `-` removed,
or `!` for values of unrelated types; the left side of a changed value is
printed in one colour and the right in the other. `d` and `D` jump between
differences, and everything else — lazy expansion, `m` to switch between the
semantic and field views, `y` to copy a path — works exactly as it does on a
single object.

`names` labels the two sides and roots their path expressions, so pass the real
variable names and the detail pane will show you `old.config.lr` against
`new.config.lr`.

```julia
julia> narcissus(before, after; names=("before", "after"))
```

A comparison bottoms out where the two sides stop lining up: values of
differently named types are reported as a type change rather than zipped field
by field. See [`Diff`](@ref) and [`diff_status`](@ref).
"""
function narcissus(@nospecialize(x), @nospecialize(y);
                   names::Tuple{AbstractString,AbstractString}=("left", "right"),
                   limit::Int=DEFAULT_LIMIT, expand::Int=8,
                   mode=Semantic(), kwargs...)
    lname, rname = String(names[1]), String(names[2])
    root = root_node(Diff(x, y), lname; limit, mode=exploration_mode(mode))
    root.key = "$lname ⇄ $rname"
    expand_differences!(root, expand - 1)
    m = Explorer(; tree = ObjectTree(root), names = (lname, rname))
    node_status(root) === :same && notify!(m, "the two objects are identical")
    app(warm!(m); kwargs...)
    selected_value(m)
end

"""
    @narcissus expr
    @narcissus expr₁ expr₂
    @narcissus expr key=value...

Explore (or compare) the value of an expression, naming the root after the
expression itself.

The point is the paths. `narcissus(model.layers[2])` roots every path at a
generic `obj`, so `y` hands you `obj.weights` — true, but not something you can
paste anywhere. The macro captures the source text instead:

```julia
julia> @narcissus model.layers[2]      # `y` now yields model.layers[2].weights
julia> @narcissus before after         # rooted at `before` and `after`
julia> @narcissus model mode=:fields   # keyword arguments pass straight through
```

An explicit `name` or `names` wins over the captured text.
"""
macro narcissus(args...)
    positional = Any[]
    options = Any[]
    for a in args
        if a isa Expr && a.head === :(=) && a.args[1] isa Symbol
            push!(options, Expr(:kw, a.args[1], esc(a.args[2])))
        elseif a isa Expr && a.head === :parameters
            append!(options, a.args)
        else
            push!(positional, a)
        end
    end
    named = Set(o isa Expr ? o.args[1] : o for o in options)

    if length(positional) == 1
        :name in named ||
            pushfirst!(options, Expr(:kw, :name, string(positional[1])))
        return Expr(:call, :narcissus, Expr(:parameters, options...),
                    esc(positional[1]))
    elseif length(positional) == 2
        :names in named || pushfirst!(options, Expr(:kw, :names,
            (string(positional[1]), string(positional[2]))))
        return Expr(:call, :narcissus, Expr(:parameters, options...),
                    esc(positional[1]), esc(positional[2]))
    end
    return :(throw(ArgumentError(
        "@narcissus takes one expression to explore, or two to compare")))
end
