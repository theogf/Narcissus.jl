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
    try
        if isbitstype(eltype(x))
            # Every slot of a bits array holds a value; iterate it directly.
            for v in x
                a = anomaly(v)
                a === nothing && continue
                a === :nan && return :nan      # the loudest wins; stop looking
                found = something(found, a)
            end
        else
            # A `Memory` or `Vector{Any}` can have unassigned slots — a `Dict`'s
            # internal storage is full of them — and reading one throws. They
            # are the container's business, not an anomaly in the value.
            for i in eachindex(x)
                isassigned(x, i) || continue
                a = anomaly(x[i])
                a === nothing && continue
                a === :nan && return :nan
                found = something(found, a)
            end
        end
    catch
        return found
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

"Julia's per-object tag word, which `sizeof` does not include."
const OBJECT_HEADER = 8

"""
    SIZE_BUDGET

How many distinct objects a size measurement may visit before giving up.
"""
const SIZE_BUDGET = 20_000

"""
    skip_for_size(x) -> Bool

Whether `x` is runtime machinery rather than the user's data, and so should be
counted as nothing and never walked into.

This is not fussiness. `Base.summarysize` of a single `Method` is **111 MB**:
a method reaches its module, its specializations and from there most of the
runtime. Measuring the twenty rows of a function's method list would walk that
twenty times over, which is enough to hang or exhaust a session — and the
answer was never a fact about anyone's data.
"""
skip_for_size(@nospecialize(x)) =
    x isa Module || x isa Type || x isa Method || x isa Core.MethodInstance ||
    x isa Core.TypeName || x isa Core.SimpleVector

"""
    bounded_size(x; budget=SIZE_BUDGET) -> (bytes, truncated)

Retained size of `x`, counting shared objects once, with a hard cap on how far
it will look.

`Base.summarysize` answers the same question but cannot be told to stop, and
walks into runtime machinery that is not the caller's data — see
[`skip_for_size`](@ref). This walk is bounded and refuses those, so the memory
view cannot be made to hang the app by pointing it at the wrong row. When the
budget runs out the result is reported as a lower bound rather than a number
pretending to be exact.
"""
function bounded_size(@nospecialize(x); budget::Int=SIZE_BUDGET)
    seen = Base.IdSet{Any}()
    left = Ref(budget)
    bytes = _measure(x, seen, left)
    (bytes, left[] <= 0)
end

function _measure(@nospecialize(v), seen::Base.IdSet, left::Ref{Int})
    left[] <= 0 && return 0
    skip_for_size(v) && return 0
    isbits(v) && return sizeof(v)
    v in seen && return 0          # identity, so a shared child counts once
    push!(seen, v)
    left[] -= 1

    total = _shallow_size(v) + OBJECT_HEADER
    try
        if v isa AbstractArray
            # A bits array's elements are already inside `sizeof`.
            isbitstype(eltype(v)) && return total
            for i in eachindex(v)
                left[] <= 0 && break
                isassigned(v, i) || continue
                total += _measure(v[i], seen, left)
            end
        elseif !(v isa AbstractString || v isa Symbol)
            for i in 1:nfields(v)
                left[] <= 0 && break
                isdefined(v, i) || continue
                total += _measure(getfield(v, i), seen, left)
            end
        end
    catch
        # An exotic container that will not be walked still has its own size.
    end
    total
end

"The object's own storage, before anything it points at."
_shallow_size(@nospecialize(v)) = try
    (v isa AbstractArray || v isa AbstractString) ? sizeof(v) : sizeof(typeof(v))
catch
    0
end

"""
    byte_size(x) -> Int

Retained size of `x` in bytes — see [`bounded_size`](@ref), whose budget this
inherits. A lower bound for anything too large to finish measuring.
"""
byte_size(@nospecialize(x)) = first(bounded_size(x))

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

The docstring attached to a function, type, module or method, rendered as
Markdown, or `nothing` when there is none.

Reached through the binding rather than the value, which is how Julia stores
docs: a generic function does not carry its own documentation, the name it is
bound to does. Anonymous functions and closures have no such binding and come
back `nothing`.

A `Method` is looked up by signature, so a method that carries its own
docstring shows that one rather than everything written about the function —
see [`doc_signature`](@ref) and [`has_method_doc`](@ref).

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
        show(context, MIME"text/plain"(), Base.Docs.doc(binding, doc_signature(x)))
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

# A method's documentation is filed under the *function's* binding, not the
# method's: `Docs.Binding` resolves `push!` to `Base` however many packages add
# methods to it. The function comes back out of the signature rather than out
# of `m.module`, which is where the method was written, not where the name
# lives.
function doc_binding(m::Method)
    try
        ftype = Base.unwrap_unionall(m.sig).parameters[1]
        isdefined(ftype, :instance) ?
            doc_binding(ftype.instance) : Base.Docs.Binding(m.module, m.name)
    catch
        nothing
    end
end

"""
    doc_signature(x) -> Type

The argument-tuple type a documentation lookup should match, `Union{}` for
anything but a `Method` — a bare binding wants every docstring filed under it.

For a method it is the method's own signature with the function's type dropped,
which is the shape the docsystem keys signature-specific docstrings by. Handing
that to `Docs.doc` is what makes `?push!(::Vector, ::Any)` narrower than
`?push!`.
"""
doc_signature(@nospecialize(x)) = Union{}
doc_signature(m::Method) = Base.tuple_type_tail(m.sig)

"""
    has_method_doc(m::Method) -> Bool

Whether a docstring is filed under this method's own signature, as opposed to
one written for the function as a whole.

The distinction is worth drawing because [`docstring`](@ref) falls back to
every docstring on the binding when a method has none of its own — useful, but
not a description of *this* method, and the pane should say which it is
showing. Reads the docsystem's tables directly; anything unexpected there is
answered with `false`, which only costs the note.
"""
function has_method_doc(m::Method)
    binding = doc_binding(m)
    binding === nothing && return false
    try
        sig = doc_signature(m)
        for mod in Base.Docs.modules
            table = Base.Docs.meta(mod; autoinit=false)
            table === nothing && continue
            multidoc = get(table, binding, nothing)
            multidoc === nothing && continue
            any(msig -> sig <: msig, multidoc.order) && return true
        end
        false
    catch
        false
    end
end

# ── Clipboard ────────────────────────────────────────────────────────

"""
    CLIPBOARD_COMMANDS

Commands tried, in order, to put text on the system clipboard.

Tachikoma's own `clipboard_copy!` knows only `xclip`, which is not installed on
a great many Linux desktops — Wayland sessions use `wl-copy` — and it swallows
the failure, so the app cheerfully reports a copy that never happened. Trying
the alternatives and reporting the truth is worth the twenty lines.
"""
const CLIPBOARD_COMMANDS = if Sys.isapple()
    [`pbcopy`]
elseif Sys.iswindows()
    [`clip`]
else
    [`wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`]
end

"""
    copy_to_clipboard(text) -> Bool

Put `text` on the system clipboard, returning whether anything actually took
it. `false` means every available tool was missing or refused — the caller is
expected to say so rather than claim success.
"""
function copy_to_clipboard(text::AbstractString)
    for command in CLIPBOARD_COMMANDS
        Sys.which(first(command)) === nothing && continue
        try
            open(pipeline(command; stderr=devnull), "w") do io
                write(io, text)
            end
            return true
        catch
            continue
        end
    end
    false
end

"Name the tools that could have taken the text, for a useful failure message."
clipboard_hint() = "no clipboard tool found (tried " *
                   join((first(c) for c in CLIPBOARD_COMMANDS), ", ") * ")"
