"""
    NarcissusTablesExt

A semantic view for [Tables.jl](https://github.com/JuliaData/Tables.jl) tables:
a table decomposes into its columns.

Table-ness is a trait, not a supertype — `Tables.istable(DataFrame)` is true
without `DataFrame` sharing anything to dispatch on — so this registers with
`Narcissus.register_semantic!` rather than adding a `components` method.
Registrations are consulted only for values no method already claims, which is
why a `Vector{<:NamedTuple}` stays an array of rows: that is the shape it
prints as, and its elements are already one per row.
"""
module NarcissusTablesExt

using Narcissus: Narcissus, Component
using Tables

function __init__()
    Narcissus.register_semantic!(_is_table, _column_count, _column_components)
end

# A `NamedTuple` of vectors *is* a column table, but the generic field view
# already shows exactly those columns under exactly those names, and reaches
# them by `{}.a` rather than `Tables.getcolumn({}, :a)`. Nothing to add.
_is_table(@nospecialize(x)) = !(x isa NamedTuple) && Tables.istable(x)

# The schema knows the column names without materialising a single column,
# which is what makes this cheap enough to run on every node. It is allowed to
# come back `nothing` — an unknown schema, or a table that has no method — and
# then there is no way to count but to ask the columns.
function _column_count(@nospecialize(x))
    names = _schema_names(x)
    names === nothing ? length(Tables.columnnames(Tables.columns(x))) : length(names)
end

function _schema_names(@nospecialize(x))
    sch = try
        Tables.schema(x)
    catch
        return nothing
    end
    sch === nothing ? nothing : sch.names
end

function _column_components(@nospecialize(x))
    cols = Tables.columns(x)
    (_column_component(cols, n) for n in Tables.columnnames(cols))
end

# `repr` rather than `:$name`, so a column called `var"total (€)"` still yields
# a path that parses.
_column_component(@nospecialize(cols), name::Symbol) = Component(
    String(name),
    "Tables.getcolumn({}, $(repr(name)))",
    Narcissus._tryget(() -> Tables.getcolumn(cols, name));
    kind = :field,
)

end
