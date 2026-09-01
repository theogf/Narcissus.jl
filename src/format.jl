# ═══════════════════════════════════════════════════════════════════════
# Formatting ── turning values into the short strings a tree row can hold
# ═══════════════════════════════════════════════════════════════════════

"Truncate `s` to `n` display columns, marking the cut with an ellipsis."
function truncate_text(s::AbstractString, n::Int)
    n <= 0 && return ""
    length(s) <= n && return String(s)
    String(first(s, max(1, n - 1))) * "…"
end

"Render a thrown value — which need not be an `Exception` — as text."
err_string(e) =
    try
        sprint(showerror, e)
    catch
        string(e)
    end

"Collapse a multi-line rendering onto a single line."
squash(s::AbstractString) = replace(strip(s), r"\s*\n\s*" => " ")

"""
    OutputFull

Thrown at a `show` method that has written all anyone is going to read.
"""
struct OutputFull <: Exception end

"""
    CappedIO(cap)

An `IO` that takes `cap` bytes and then stops the writer with [`OutputFull`](@ref).

`:limit` bounds how much of a *container* Julia prints, and nothing bounds how
much of a *structure* it prints: `show` of a 5 000-long linked list walks all
5 000 links to produce the sixty characters a row has room for, and a struct
that nests deeply enough will do the same. Since the caller knows how much text
it can use, the honest bound is on the output, not on the value — a preview
stops after a couple of hundred bytes no matter what it was printing.

A `show` method that swallows exceptions simply runs to completion as before,
which is slow but still correct.
"""
mutable struct CappedIO <: IO
    buf::IOBuffer
    cap::Int
    written::Int
end

CappedIO(cap::Int) = CappedIO(IOBuffer(), cap, 0)

function Base.write(c::CappedIO, byte::UInt8)
    c.written >= c.cap && throw(OutputFull())
    c.written += 1
    write(c.buf, byte)
end

function Base.unsafe_write(c::CappedIO, p::Ptr{UInt8}, n::UInt)
    room = c.cap - c.written
    room <= 0 && throw(OutputFull())
    taken = min(n, UInt(room))
    written = unsafe_write(c.buf, p, taken)
    c.written += Int(written)
    written < n && throw(OutputFull())
    written
end

"""
    capped_text(io) -> String

What a [`CappedIO`](@ref) collected, trimmed to whole characters — a cap counts
bytes, and stopping mid-character would leave a string nothing can measure the
width of.
"""
function capped_text(c::CappedIO)
    bytes = take!(c.buf)
    n = length(bytes)
    while n > 0
        text = String(@view bytes[1:n])
        isvalid(text) && return text
        n -= 1
    end
    ""
end

"How many bytes of `show` output a one-line preview is allowed to cost."
const PREVIEW_CAP = 8

"""
    compact_show(v; width, height) -> String

`show(v)` under `:compact` and `:limit`, flattened to one line and clipped.

Never throws: a broken `show` method becomes a visible marker instead of a
crashed explorer, and one that goes on forever is stopped once it has written
[`PREVIEW_CAP`](@ref) times the characters that will be kept.
"""
function compact_show(@nospecialize(v); width::Int = 60, height::Int = 2)
    try
        capped = CappedIO(PREVIEW_CAP * max(20, width))
        ctx = IOContext(
            capped,
            :compact => true,
            :limit => true,
            :color => false,
            :displaysize => (height, max(20, width + 8)),
        )
        try
            show(ctx, v)
        catch e
            e isa OutputFull || rethrow()
        end
        return truncate_text(squash(capped_text(capped)), width)
    catch e
        return "«show error: $(nameof(typeof(e)))»"
    end
end

"""
    plain_show(v; width, height) -> String

The `show(io, MIME"text/plain"(), v)` rendering used by the detail pane, under
`:limit` at the given `displaysize`, so a million-element array prints the
handful of rows that fit rather than a million.

`height` is what the caller can actually display — see
[`refresh_detail!`](@ref), which asks for the visible window plus a little,
and asks again for more only when you scroll past it.
"""
function plain_show(@nospecialize(v); width::Int = 80, height::Int = 200)
    try
        # Room for the pane several times over, so nothing you can actually
        # read is ever cut — and a `show` with no bottom to it still stops.
        capped = CappedIO(4 * max(4, height) * max(20, width))
        ctx = IOContext(
            capped,
            :limit => true,
            :color => false,
            :displaysize => (max(4, height), max(20, width)),
        )
        try
            show(ctx, MIME"text/plain"(), v)
        catch e
            e isa OutputFull || rethrow()
        end
        return capped_text(capped)
    catch e
        return "«show error: $(nameof(typeof(e)))»"
    end
end

"""
    type_string(node) -> String

Full type name of a node's value, or a marker for the synthetic node kinds.

Cached on the node, like the preview and for the same reason: this is drawn on
every visible row of every frame, and `string(typeof(v))` is not cheap —
Julia's type printing searches the loaded modules for an alias to prefer
(`Vector{Float64}` over `Array{Float64, 1}`), which on a screenful of rows at
sixty frames a second is the single most expensive thing in the frame.
"""
function type_string(n::ObjNode)
    n._type === nothing || return n._type
    n._type = _type_string(n)
end

function _type_string(n::ObjNode)
    n.kind === :elided && return ""
    (n.value isa Undef || n.value isa AccessError) && return ""
    v = n.value
    if v isa Diff
        v.x isa Absent && return string(typeof(v.y))
        v.y isa Absent && return string(typeof(v.x))
        tx, ty = string(typeof(v.x)), string(typeof(v.y))
        return tx == ty ? tx : tx * " → " * ty
    end
    # `typeof(String)` is `DataType`, which tells the reader nothing they want
    # to know. Say "type" and let the value column carry the actual type.
    v isa Type && return "type"
    # `typeof(sin)` prints as `typeof(sin)`, which only repeats the value.
    v isa Function && return is_macro(v) ? "macro" : "function"
    string(typeof(v))
end

"""
    preview(node) -> String

Short value rendering shown after the type on a tree row. Computed on first
use and cached: only rows you actually look at pay for their `show` method.
"""
function preview(n::ObjNode)
    n._preview === nothing || return n._preview
    n._preview = compute_preview(n)
end

"""
    compute_preview(node) -> String

The preview text, computed and *not* stored.

Kept apart from [`preview`](@ref) because this is what runs off the main task
(see `Narcissus.measure`): the result travels back as an event and is written
to the node there, so the walk that produced it never touches the tree.
"""
function compute_preview(n::ObjNode)
    if n.kind === :elided
        remaining = n.total - (n.next_start - 1)
        "$remaining more"
    elseif n.value isa Undef
        "#undef"
    elseif n.value isa AccessError
        squash(truncate_text(err_string(n.value.err), 60))
    elseif n.kind === :cycle
        "↺ already shown above"
    elseif n.value isa Diff
        _diff_preview(n.value, node_status(n))
    else
        compact_show(n.value)
    end
end

function _diff_preview(d::Diff, status::Symbol)
    status === :same && return compact_show(d.x)
    status === :added && return compact_show(d.y)
    status === :removed && return compact_show(d.x)
    compact_show(d.x; width = 28) * " → " * compact_show(d.y; width = 28)
end

"""
    SPINNER

The frames of the "still reading this one" marker, a braille wheel.

A row whose value has not been rendered yet shows this instead, and keeps
showing it while the render happens somewhere else — the point being that the
frame is drawn either way. `show` methods that take a visible amount of time
exist (a deeply nested structure, a value that computes something to print
itself), and before this the whole app stopped for them.
"""
const SPINNER = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')

"""
    SLOW_RENDER_NS

How long a value may take to print before the tree stops printing values in the
frame at all — see `Narcissus.ObjectTree`.

Well over what an ordinary `show` costs and well under a frame, so it is only
ever tripped by a `show` method doing real work.
"""
const SLOW_RENDER_NS = 10_000_000

"The spinner frame for a tick count, slowed to something the eye can follow."
spinner_char(tick::Int) = SPINNER[mod1(tick ÷ 4 + 1, length(SPINNER))]

"The value column of a row whose preview has not arrived yet."
pending_spans(tick::Int) = [(string(spinner_char(tick)), tstyle(:text_dim))]

"""
    preview_spans(node, selected) -> Vector{Tuple{String,Style}}

The value column of a tree row, split into styled pieces. Ordinary values are
one piece; a comparison is the left side, an arrow, and the right side, so the
two are told apart by colour and not just by reading order.
"""
function preview_spans(n::ObjNode, selected::Bool = false)
    pv = preview(n)
    isempty(pv) && return Tuple{String,Style}[]
    plain = selected ? tstyle(:text_bright) : tstyle(:text)

    (n.value isa Diff && n.kind !== :cycle) || return [(pv, plain)]

    d = n.value
    status = node_status(n)
    # The left side is one colour and the right the other, throughout; a value
    # that exists on only one side simply wears that side's colour.
    status === :same && return [(pv, tstyle(:text_dim))]
    status === :added && return [(pv, tstyle(:warning))]
    status === :removed && return [(pv, tstyle(:primary))]
    [
        (compact_show(d.x; width = 28), tstyle(:primary)),
        (" → ", tstyle(:border, dim = true)),
        (compact_show(d.y; width = 28), tstyle(:warning)),
    ]
end

"""
    status_marker(status) -> (Char, Style)

Row glyph and colour for a comparison status; `:none` draws nothing.

Green means the two sides match and red means they do not — one question, one
colour, answered the same way everywhere the status appears. The glyph says
*how* they fail to match, so `+` and `-` stay red rather than borrowing green
for "added" and making green mean two different things.
"""
function status_marker(status::Symbol)
    status === :same && return ('·', tstyle(:success, bold = true))
    status === :changed && return ('~', tstyle(:error, bold = true))
    status === :added && return ('+', tstyle(:error, bold = true))
    status === :removed && return ('-', tstyle(:error, bold = true))
    status === :type && return ('!', tstyle(:error, bold = true))
    (' ', tstyle(:text))
end

"Green when the two sides match, red when they do not."
status_style(status::Symbol) =
    status === :same ? tstyle(:success, bold = true) : tstyle(:error, bold = true)

# ── Detail pane ──────────────────────────────────────────────────────

_dim() = tstyle(:text_dim)
_lbl() = tstyle(:text_dim)

function _row!(
    spans,
    label::AbstractString,
    value::AbstractString,
    style::Style = tstyle(:text),
)
    isempty(value) && return spans
    push!(spans, Span(rpad(label, 9), _lbl()))
    push!(spans, Span(value, style))
    push!(spans, Span("\n", RESET))
    spans
end

"`supertype`, or an empty string for the types that do not have one."
_supertype_string(@nospecialize(T::Type)) =
    try
        string(supertype(T))
    catch
        ""
    end

"Human-readable description of what kind of thing a value is."
function kind_string(@nospecialize(v))
    v isa Absent && return "absent on this side"
    v isa Module && return "module"
    if v isa Type
        isabstracttype(v) && return "abstract type"
        v isa UnionAll && return "parametric type"
        v isa Union && return "type union"
        return ismutabletype(v) ? "mutable struct type" : "struct type"
    end
    v isa Undef && return "undefined field"
    v isa AccessError && return "inaccessible"
    T = typeof(v)
    v isa AbstractDict && return "dictionary"
    v isa AbstractSet && return "set"
    v isa AbstractArray && return "array"
    v isa Tuple && return "tuple"
    v isa NamedTuple && return "named tuple"
    v isa Method && return "method"
    v isa Function && return is_macro(v) ? "macro" : "function"
    v isa Type && return "type"
    v isa Module && return "module"
    isprimitivetype(T) && return "primitive"
    ismutabletype(T) ? "mutable struct" : "struct"
end

"""
    detail_spans(node, width) -> Vector{Span}

The right-hand pane: where the value lives, what it is, and how it prints.
"""
function detail_spans(n::ObjNode, width::Int; names = nothing, height::Int = 60)
    n.value isa Diff && return diff_detail_spans(n, width, height, names)
    spans = Span[]
    v = n.value

    _row!(spans, "path", n.path, tstyle(:accent))
    _row!(spans, "type", type_string(n), tstyle(:secondary))
    _row!(spans, "kind", kind_string(v), tstyle(:text))
    if has_semantic_view(v)
        _row!(
            spans,
            "view",
            "$(mode_name(n.mode))  (m: $(mode_name(other_mode(n.mode))))",
            tstyle(:warning),
        )
    end

    if n.kind === :elided
        _row!(
            spans,
            "elided",
            "showing $(n.next_start - 1) of $(n.total); " *
            "press Enter to load $(n.limit) more",
            tstyle(:warning),
        )
        return spans
    end
    if n.kind === :cycle
        _row!(spans, "cycle", "this value is one of its own ancestors", tstyle(:warning))
    end

    _row!(spans, "parts", string(n_components(n.mode, v)), tstyle(:text))

    if v isa Module
        _row!(spans, "parent", string(parentmodule(v)), tstyle(:text))
        _row!(spans, "public", string(length(module_names(v))), tstyle(:text))
        _row!(spans, "all", string(length(module_names(v; all = true))), _dim())
        push!(spans, Span("\n" * "─"^max(1, width - 1) * "\n", tstyle(:border, dim = true)))
        push!(
            spans,
            Span(
                "Semantic view lists what the module offers; the field " *
                "view lists everything it defines. Press f to keep " *
                "only the functions, the macros, the types, the modules " *
                "or the values.\n\n",
                _dim(),
            ),
        )
        _docs!(spans, v, width; separator = false)
        return spans
    elseif v isa Type
        # `supertype` is a `DataType` question: a `UnionAll` or a `Union` has
        # no single answer and throws rather than saying so.
        _row!(spans, "super", _supertype_string(v), tstyle(:secondary))
        _row!(spans, "fields", string(n_components(n.mode, v)), tstyle(:text))
        _row!(spans, "abstract", string(isabstracttype(v)), _dim())
        _row!(spans, "isbits", string(isbitstype(v)), _dim())
        push!(spans, Span("\n" * "─"^max(1, width - 1) * "\n", tstyle(:border, dim = true)))
        for i = 1:n_components(n.mode, v)
            # A tuple type's field "names" are integers, not symbols.
            name = fieldname(v, i)
            label = name isa Integer ? "[$name]" : String(name)
            push!(spans, Span("  " * label, tstyle(:primary)))
            push!(spans, Span("::" * string(fieldtype(v, i)) * "\n", tstyle(:secondary)))
        end
        _docs!(spans, v, width)
        return spans
    elseif v isa Function
        _row!(spans, "methods", string(length(methods(v))), tstyle(:text))
        _row!(spans, "defined", string(parentmodule(v)), _dim())
        _docs!(spans, v, width)
        return spans
    elseif v isa Method
        # What you want from a method is its signature and its documentation.
        # Its `show` output says the first of those and its fields are compiler
        # bookkeeping, so neither earns the space.
        _row!(spans, "function", string(v.name), tstyle(:primary))
        _row!(spans, "args", _method_key(v), tstyle(:secondary))
        _row!(spans, "defined", string(v.module), tstyle(:text))
        _row!(spans, "source", string(basename(String(v.file)), ":", v.line), _dim())
        _docs!(spans, v, width)
        return spans
    elseif v isa AbstractArray
        _row!(spans, "size", string(size(v)), tstyle(:text))
        _row!(spans, "eltype", string(eltype(v)), tstyle(:text))
    elseif v isa AbstractDict
        _row!(spans, "length", string(length(v)), tstyle(:text))
        _row!(spans, "keytype", string(keytype(v)), tstyle(:text))
        _row!(spans, "valtype", string(valtype(v)), tstyle(:text))
    elseif v isa AbstractSet || v isa Tuple
        _row!(spans, "length", string(length(v)), tstyle(:text))
    end

    if !(v isa Undef || v isa AccessError)
        T = typeof(v)
        # `sizeof`, not `summarysize`: shallow and O(1), so selecting a node
        # never walks an arbitrarily large object graph.
        nb = try
            string(sizeof(v), " bytes")
        catch
            ""
        end
        _row!(spans, "sizeof", nb, tstyle(:text))
        _row!(spans, "super", string(supertype(T)), _dim())
        fns = fieldnames(T)
        if !isempty(fns) && !(v isa Tuple)
            _row!(spans, "fields", truncate_text(join(fns, ", "), 4 * width), _dim())
        end
    end

    # One column short of the pane: the paragraph keeps a column for its scrollbar.
    push!(spans, Span("\n" * "─"^max(1, width - 1) * "\n", tstyle(:border, dim = true)))

    if v isa Undef
        push!(spans, Span("This field is declared but never assigned.\n", tstyle(:warning)))
    elseif v isa AccessError
        push!(spans, Span(err_string(v.err), tstyle(:error)))
    else
        push!(spans, Span(plain_show(v; width, height), tstyle(:text)))
    end
    spans
end

# ── Detail pane, comparison ──────────────────────────────────────────

const STATUS_TEXT = Dict(
    :same => "identical",
    :changed => "changed",
    :added => "added on the right",
    :removed => "removed on the right",
    :type => "different types",
)

"Swap the root name of a path so it names the right-hand object instead."
function rename_root(path::AbstractString, names)
    names === nothing && return String(path)
    left, right = names
    startswith(path, left) || return String(path)
    right * path[(ncodeunits(left)+1):end]
end

"""
    diff_detail_spans(node, width, names) -> Vector{Span}

The right-hand pane for a comparison node: where each side lives, what each
side is, and how each side prints — the left in one colour, the right in the
other, matching the tree.
"""
function diff_detail_spans(n::ObjNode, width::Int, height::Int, names)
    d = n.value
    status = node_status(n)
    spans = Span[]
    lname, rname = names === nothing ? ("left", "right") : names

    _row!(spans, "status", get(STATUS_TEXT, status, string(status)), status_style(status))
    if status === :type
        _row!(
            spans,
            "types",
            string(typeof(d.x)) * "  ≠  " * string(typeof(d.y)),
            tstyle(:error),
        )
    end
    _row!(spans, lname, d.x isa Absent ? "—" : n.path, tstyle(:primary))
    _row!(spans, rname, d.y isa Absent ? "—" : rename_root(n.path, names), tstyle(:warning))
    if has_semantic_view(d)
        _row!(
            spans,
            "view",
            "$(mode_name(n.mode))  (m: $(mode_name(other_mode(n.mode))))",
            tstyle(:text),
        )
    end
    _row!(spans, "parts", string(n_components(n.mode, d)), tstyle(:text))

    push!(spans, Span("\n", RESET))
    # Each side gets half the budget; they are stacked in the same pane.
    per_side = max(4, height ÷ 2)
    _side!(spans, lname, d.x, tstyle(:primary), width, per_side)
    _side!(spans, rname, d.y, tstyle(:warning), width, per_side)
    spans
end

function _side!(
    spans,
    label::AbstractString,
    @nospecialize(v),
    style::Style,
    width::Int,
    height::Int,
)
    push!(spans, Span("─── $label ", style))
    push!(
        spans,
        Span("─"^max(1, width - textwidth(label) - 6) * "\n", tstyle(:border, dim = true)),
    )
    if v isa Absent
        push!(spans, Span("(absent)\n\n", tstyle(:text_dim)))
        return spans
    end
    _row!(spans, "type", string(typeof(v)), tstyle(:secondary))
    push!(spans, Span(plain_show(v; width, height) * "\n\n", tstyle(:text)))
end

# ── Memory view ──────────────────────────────────────────────────────

"""
    MEMORY_COLUMN_WIDTH

Width of the memory column: `1023 KiB ▕████····▏ 100%`. Fixed, because the
column is right-aligned to the pane and a variable width would stop the sizes
and percentages lining up — which is the entire reason to look at them.
"""
const MEMORY_COLUMN_WIDTH = 9 + 1 + 10 + 5

"""
    memory_spans(node) -> Vector{Tuple{String,Style}}

The memory column: retained size, a share bar, and the share as a percentage.

The share is what makes it readable — an absolute size tells you a node is
large, but the proportion tells you whether it is the reason its parent is.
Rendered as a right-aligned block of [`MEMORY_COLUMN_WIDTH`](@ref) cells so
that sibling rows can be compared down the column rather than read one by one.
"""
function memory_spans(n::ObjNode, tree = nothing)
    # Runtime machinery declines to be measured; say so rather than claim "0 B".
    skip_for_size(node_measurand(n)) && return [(lpad("—", 9), tstyle(:text_dim))]

    # Measuring walks the object, so the renderer asks for it and draws a
    # placeholder until the answer comes back.
    parent = n.parent
    for node in (n, parent)
        node === nothing && continue
        bytes_state(node) < 0 && tree !== nothing && request!(tree, node, :bytes)
    end
    bytes_state(n) < 0 && return [(lpad("…", 9), tstyle(:text_dim))]

    bytes = node_bytes(n)
    parent_bytes =
        parent === nothing || bytes_state(parent) < 0 ? bytes : node_bytes(parent)
    share = parent_bytes > 0 ? bytes / parent_bytes : 1.0

    heavy = share > 0.5 ? tstyle(:warning, bold = true) : tstyle(:text)
    # A capped measurement is a lower bound, and says so rather than rounding
    # a number it never finished computing.
    shown = n._bytes_capped ? ">" * human_bytes(bytes) : human_bytes(bytes)
    [
        (lpad(shown, 9), heavy),
        (" " * share_bar(share), tstyle(:text_dim)),
        (lpad(string(round(Int, 100share), "%"), 5), tstyle(:text_dim)),
    ]
end

"""
    _docs!(spans, value, width; separator=true)

Append the value's rendered documentation, or a note that there is none.

What you want from a function, a type or a method is almost never its `show`
output — it is what the thing is *for*. The Markdown comes back as ANSI, which
`parse_ansi` splits into styled spans, so the pane shows headers, emphasis and
code blocks rather than a wall of asterisks.

A value that has nothing of its own to say borrows from the name it shares —
see [`doc_object`](@ref) — and the borrowing is labelled.
"""
function _docs!(spans, @nospecialize(v), width::Int; separator::Bool = true)
    separator &&
        push!(spans, Span("\n" * "─"^max(1, width - 1) * "\n", tstyle(:border, dim = true)))
    text = docstring(v; width = max(20, width - 1))
    text === nothing && return push!(spans, Span("(no documentation)\n", _dim()))
    # Nothing written about the thing itself falls back to what was written
    # about its methods or its constructors, which is worth showing and worth
    # labelling — the alternative is a page of prose that looks like it
    # describes the value you are looking at.
    note = if v isa Method && !has_method_doc(v)
        "(nothing on this method — the function's documentation)\n\n"
    elseif v isa Type && !has_own_doc(v)
        "(nothing on the type itself — its constructors' documentation)\n\n"
    else
        ""
    end
    isempty(note) || push!(spans, Span(note, _dim()))
    append!(spans, parse_ansi(text))
    spans
end

# ── Wrapping ─────────────────────────────────────────────────────────

"""
    wrap_spans(spans, width) -> Vector{Vector{Tuple{String,Style}}}

Lay styled text out into lines of at most `width` columns, breaking at spaces
where possible and mid-word only when a word cannot fit on a line of its own.
Explicit newlines in the span text are honoured.

The point of doing this ourselves is that the result can be *cached*. A
paragraph widget re-wraps its whole content on every frame; the detail pane's
content changes only when the selection or the pane width does, so wrapping
once and drawing the visible slice is the difference between a per-frame cost
proportional to the rendered value and one proportional to the screen.
"""
function wrap_spans(spans::Vector{Span}, width::Int)
    lines = Vector{Tuple{String,Style}}[]
    width < 1 && return lines
    push!(lines, Tuple{String,Style}[])
    col = Ref(0)

    newline!() = (push!(lines, Tuple{String,Style}[]); col[] = 0)
    function emit!(text::AbstractString, style::Style)
        isempty(text) && return
        push!(lines[end], (String(text), style))
        col[] += textwidth(text)
    end

    for span in spans
        for (i, part) in enumerate(split(span.content, '\n'; keepempty = true))
            i > 1 && newline!()
            isempty(part) && continue
            for token in _tokens(part)
                w = textwidth(token)
                if w > width
                    # Longer than a whole line: break it wherever it lands.
                    chars = collect(token)
                    while !isempty(chars)
                        room = width - col[]
                        room <= 0 && (newline!(); room = width)
                        take = min(room, length(chars))
                        emit!(String(chars[1:take]), span.style)
                        chars = chars[(take+1):end]
                    end
                elseif col[] + w > width
                    # A wrapped line never starts with the space that broke it.
                    all(isspace, token) && (newline!(); continue)
                    newline!()
                    emit!(token, span.style)
                else
                    emit!(token, span.style)
                end
            end
        end
    end
    lines
end

"Split text into alternating runs of spaces and non-spaces, keeping both."
function _tokens(s::AbstractString)
    out = String[]
    chars = collect(s)
    i = 1
    while i <= length(chars)
        spacey = isspace(chars[i])
        j = i
        while j <= length(chars) && isspace(chars[j]) == spacey
            j += 1
        end
        push!(out, String(chars[i:(j-1)]))
        i = j
    end
    out
end
