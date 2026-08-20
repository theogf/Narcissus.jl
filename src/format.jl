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
err_string(e) = try
    sprint(showerror, e)
catch
    string(e)
end

"Collapse a multi-line rendering onto a single line."
squash(s::AbstractString) = replace(strip(s), r"\s*\n\s*" => " ")

"""
    compact_show(v; width, height) -> String

`show(v)` under `:compact` and `:limit`, flattened to one line and clipped.
Never throws: a broken `show` method becomes a visible marker instead of a
crashed explorer.
"""
function compact_show(@nospecialize(v); width::Int=60, height::Int=2)
    try
        io = IOBuffer()
        ctx = IOContext(io, :compact => true, :limit => true, :color => false,
                        :displaysize => (height, max(20, width + 8)))
        show(ctx, v)
        return truncate_text(squash(String(take!(io))), width)
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
function plain_show(@nospecialize(v); width::Int=80, height::Int=200)
    try
        io = IOBuffer()
        ctx = IOContext(io, :limit => true, :color => false,
                        :displaysize => (max(4, height), max(20, width)))
        show(ctx, MIME"text/plain"(), v)
        return String(take!(io))
    catch e
        return "«show error: $(nameof(typeof(e)))»"
    end
end

"Full type name of a node's value, or a marker for the synthetic node kinds."
function type_string(n::ObjNode)
    n.kind === :elided && return ""
    (n.value isa Undef || n.value isa AccessError) && return ""
    v = n.value
    if v isa Diff
        v.x isa Absent && return string(typeof(v.y))
        v.y isa Absent && return string(typeof(v.x))
        tx, ty = string(typeof(v.x)), string(typeof(v.y))
        return tx == ty ? tx : tx * " → " * ty
    end
    string(typeof(v))
end

"""
    preview(node) -> String

Short value rendering shown after the type on a tree row. Computed on first
use and cached: only rows you actually look at pay for their `show` method.
"""
function preview(n::ObjNode)
    n._preview === nothing || return n._preview
    s = if n.kind === :elided
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
    n._preview = s
    s
end

function _diff_preview(d::Diff, status::Symbol)
    status === :same && return compact_show(d.x)
    status === :added && return compact_show(d.y)
    status === :removed && return compact_show(d.x)
    compact_show(d.x; width=28) * " → " * compact_show(d.y; width=28)
end

"""
    preview_spans(node, selected) -> Vector{Tuple{String,Style}}

The value column of a tree row, split into styled pieces. Ordinary values are
one piece; a comparison is the left side, an arrow, and the right side, so the
two are told apart by colour and not just by reading order.
"""
function preview_spans(n::ObjNode, selected::Bool=false)
    pv = preview(n)
    isempty(pv) && return Tuple{String,Style}[]
    plain = selected ? tstyle(:text_bright) : tstyle(:text)

    (n.value isa Diff && n.kind !== :cycle) || return [(pv, plain)]

    d = n.value
    status = node_status(n)
    status === :same && return [(pv, tstyle(:text_dim))]
    status === :added && return [(pv, tstyle(:success))]
    status === :removed && return [(pv, tstyle(:error))]
    [(compact_show(d.x; width=28), tstyle(:primary)),
     (" → ", tstyle(:border, dim=true)),
     (compact_show(d.y; width=28), tstyle(:warning))]
end

"Row glyph and style for a comparison status; `:none` draws nothing."
function status_marker(status::Symbol)
    status === :same && return ('·', tstyle(:text_dim))
    status === :changed && return ('~', tstyle(:accent, bold=true))
    status === :added && return ('+', tstyle(:success, bold=true))
    status === :removed && return ('-', tstyle(:error, bold=true))
    status === :type && return ('!', tstyle(:warning, bold=true))
    (' ', tstyle(:text))
end

# ── Detail pane ──────────────────────────────────────────────────────

_dim() = tstyle(:text_dim)
_lbl() = tstyle(:text_dim)

function _row!(spans, label::AbstractString, value::AbstractString,
               style::Style=tstyle(:text))
    isempty(value) && return spans
    push!(spans, Span(rpad(label, 9), _lbl()))
    push!(spans, Span(value, style))
    push!(spans, Span("\n", RESET))
    spans
end

"Human-readable description of what kind of thing a value is."
function kind_string(@nospecialize(v))
    v isa Absent && return "absent on this side"
    v isa Undef && return "undefined field"
    v isa AccessError && return "inaccessible"
    T = typeof(v)
    v isa AbstractDict && return "dictionary"
    v isa AbstractSet && return "set"
    v isa AbstractArray && return "array"
    v isa Tuple && return "tuple"
    v isa NamedTuple && return "named tuple"
    v isa Function && return "function"
    v isa Type && return "type"
    v isa Module && return "module"
    isprimitivetype(T) && return "primitive"
    ismutabletype(T) ? "mutable struct" : "struct"
end

"""
    detail_spans(node, width) -> Vector{Span}

The right-hand pane: where the value lives, what it is, and how it prints.
"""
function detail_spans(n::ObjNode, width::Int; names=nothing, height::Int=60)
    n.value isa Diff && return diff_detail_spans(n, width, height, names)
    spans = Span[]
    v = n.value

    _row!(spans, "path", n.path, tstyle(:accent))
    _row!(spans, "type", type_string(n), tstyle(:secondary))
    _row!(spans, "kind", kind_string(v), tstyle(:text))
    if has_semantic_view(v)
        _row!(spans, "view",
              "$(mode_name(n.mode))  (m: $(mode_name(other_mode(n.mode))))",
              tstyle(:warning))
    end

    if n.kind === :elided
        _row!(spans, "elided", "showing $(n.next_start - 1) of $(n.total); " *
                               "press Enter to load $(n.limit) more", tstyle(:warning))
        return spans
    end
    if n.kind === :cycle
        _row!(spans, "cycle", "this value is one of its own ancestors", tstyle(:warning))
    end

    _row!(spans, "parts", string(n_components(n.mode, v)), tstyle(:text))

    if v isa AbstractArray
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
    push!(spans, Span("\n" * "─"^max(1, width - 1) * "\n", tstyle(:border, dim=true)))

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
    right * path[(ncodeunits(left) + 1):end]
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

    _row!(spans, "status", get(STATUS_TEXT, status, string(status)),
          status === :same ? tstyle(:success) : tstyle(:warning))
    _row!(spans, lname, d.x isa Absent ? "—" : n.path, tstyle(:primary))
    _row!(spans, rname, d.y isa Absent ? "—" : rename_root(n.path, names),
          tstyle(:warning))
    if has_semantic_view(d)
        _row!(spans, "view",
              "$(mode_name(n.mode))  (m: $(mode_name(other_mode(n.mode))))",
              tstyle(:text))
    end
    _row!(spans, "parts", string(n_components(n.mode, d)), tstyle(:text))

    push!(spans, Span("\n", RESET))
    # Each side gets half the budget; they are stacked in the same pane.
    per_side = max(4, height ÷ 2)
    _side!(spans, lname, d.x, tstyle(:primary), width, per_side)
    _side!(spans, rname, d.y, tstyle(:warning), width, per_side)
    spans
end

function _side!(spans, label::AbstractString, @nospecialize(v), style::Style,
                width::Int, height::Int)
    push!(spans, Span("─── $label ", style))
    push!(spans, Span("─"^max(1, width - textwidth(label) - 6) * "\n",
                      tstyle(:border, dim=true)))
    if v isa Absent
        push!(spans, Span("(absent)\n\n", tstyle(:text_dim)))
        return spans
    end
    _row!(spans, "type", string(typeof(v)), tstyle(:secondary))
    push!(spans, Span(plain_show(v; width, height) * "\n\n", tstyle(:text)))
end
