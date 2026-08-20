# ═══════════════════════════════════════════════════════════════════════
# Inspect ── the questions you bring to an object that is misbehaving
# ═══════════════════════════════════════════════════════════════════════

"How many elements of an array to scan before taking its word for it."
const SCAN_BUDGET = 1_000_000

"""
    anomaly(x) -> Union{Nothing,Symbol}

Whether `x` is the sort of value you opened the explorer to find, and which
sort. `nothing` means "looks fine".

| Symbol     | Value                                                  |
|:-----------|:-------------------------------------------------------|
| `:nan`     | a `NaN`, or an array containing one                    |
| `:inf`     | an `Inf`, or an array containing one                   |
| `:missing` | a `missing`, or an array containing one                |
| `:empty`   | an empty container                                     |
| `:undef`   | a declared but unassigned field                        |
| `:error`   | a value that could not be retrieved                    |

`nothing` and `missing`-typed containers are not anomalies in themselves —
they are too ordinary to be worth flagging, and flagging the ordinary is how a
warning marker stops being read.

Arrays are scanned, which is why the answer is cached per node: the scan is
capped at [`SCAN_BUDGET`](@ref) elements, beyond which a large array is taken
at face value.
"""
anomaly(@nospecialize(x)) = nothing
anomaly(::Undef) = :undef
anomaly(::AccessError) = :error
anomaly(::Missing) = :missing

function anomaly(x::AbstractFloat)
    isnan(x) && return :nan
    isinf(x) && return :inf
    nothing
end

anomaly(x::AbstractDict) = isempty(x) ? :empty : nothing
anomaly(x::AbstractSet) = isempty(x) ? :empty : nothing
anomaly(x::AbstractString) = isempty(x) ? :empty : nothing

function anomaly(x::AbstractArray)
    isempty(x) && return :empty
    _scannable(eltype(x)) || return nothing
    length(x) > SCAN_BUDGET && return nothing
    found = nothing
    for v in x
        a = anomaly(v)
        a === nothing && continue
        a === :nan && return :nan       # the loudest wins; stop looking
        found = something(found, a)
    end
    found
end

# Only worth scanning when an element could plausibly be one of the values we
# are looking for — a Vector{String} has nothing to say here.
_scannable(::Type{T}) where {T} =
    T <: AbstractFloat || T <: Missing || T === Any ||
    (T isa Union && (_scannable(T.a) || _scannable(T.b)))

"Row glyph and style for an anomaly; `nothing` draws nothing."
function anomaly_marker(kind::Union{Nothing,Symbol})
    kind === :nan && return ('!', tstyle(:error, bold=true))
    kind === :inf && return ('!', tstyle(:error, bold=true))
    kind === :missing && return ('?', tstyle(:warning, bold=true))
    kind === :undef && return ('?', tstyle(:warning, bold=true))
    kind === :error && return ('!', tstyle(:error, bold=true))
    kind === :empty && return ('∅', tstyle(:text_dim))
    (' ', tstyle(:text))
end

# ── Memory ───────────────────────────────────────────────────────────

"""
    byte_size(x) -> Int

`Base.summarysize` — the whole retained graph, not the shallow `sizeof` — with
a guard, since it can throw on exotic values. This is the number that answers
"why is this thing 4 GB", and it costs a walk of the object to produce, which
is why it is computed only on request and cached per node.
"""
byte_size(@nospecialize(x)) = try
    Base.summarysize(x)
catch
    0
end

"""
    human_bytes(n) -> String

`1.4 MiB`, `912 B`. Fixed width enough to line up in a column.
"""
function human_bytes(n::Integer)
    n < 1024 && return string(n, " B")
    units = ("KiB", "MiB", "GiB", "TiB")
    x = float(n) / 1024
    for (i, u) in enumerate(units)
        if x < 1024 || i == length(units)
            # One decimal only while it buys precision, so the column never
            # grows past "1023 KiB" and the numbers stay aligned.
            digits = x < 10 ? string(round(x; digits=1)) : string(round(Int, x))
            return string(digits, " ", u)
        end
        x /= 1024
    end
    string(n, " B")
end

"A proportion as a short unicode bar, for eyeballing where the bytes went."
function share_bar(fraction::Real, width::Int=8)
    fraction = clamp(fraction, 0.0, 1.0)
    filled = round(Int, fraction * width)
    "▕" * "█"^filled * "·"^(width - filled) * "▏"
end

# ── Documentation ────────────────────────────────────────────────────

"Drop ANSI escapes, for testing what a rendering actually says."
strip_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;]*m" => "")

"""
    docstring(x; width=80, color=true) -> Union{Nothing,String}

The docstring attached to a function, type or module, rendered as Markdown, or
`nothing` when there is none.

Reached through the binding rather than the value, which is how Julia stores
docs: a generic function does not carry its own documentation, the name it is
bound to does. Anonymous functions and closures have no such binding and come
back `nothing`.

Rendering goes through Julia's own Markdown writer at the given `width`, so
headers, emphasis, lists and code blocks come out formatted rather than as raw
`**asterisks**`. The formatting arrives as ANSI escapes, which
`Tachikoma.parse_ansi` turns into styled spans — the detail pane shows what
`?components` shows in the REPL. Use [`strip_ansi`](@ref) for the bare text.

`color=false` suppresses the Markdown writer's own colouring; syntax
highlighting inside code blocks comes from Julia and stays either way.
"""
function docstring(@nospecialize(x); width::Int=80, color::Bool=true)
    binding = doc_binding(x)
    binding === nothing && return nothing
    try
        io = IOBuffer()
        context = IOContext(io, :color => color, :limit => true,
                            :displaysize => (40, max(20, width)))
        show(context, MIME"text/plain"(), Base.Docs.doc(binding))
        text = String(take!(io))
        plain = strip_ansi(text)
        (occursin("No documentation found", plain) || isempty(strip(plain))) &&
            return nothing
        text
    catch
        nothing
    end
end

"The `Docs.Binding` a value's documentation would be filed under."
doc_binding(@nospecialize(x)) = nothing

function doc_binding(x::Union{Function,Type,Module})
    try
        name = nameof(x)
        # A closure's `nameof` is a gensym like `#7`; there is no binding.
        startswith(String(name), "#") && return nothing
        Base.Docs.Binding(parentmodule(x), name)
    catch
        nothing
    end
end
