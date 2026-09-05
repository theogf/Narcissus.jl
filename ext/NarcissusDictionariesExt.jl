"""
    NarcissusDictionariesExt

Semantic views for [Dictionaries.jl](https://github.com/andyferris/Dictionaries.jl).

`AbstractDictionary` is deliberately *not* an `AbstractDict`, so nothing in
Narcissus claims it and a `Dictionary` would otherwise open as its two storage
fields — `indices` and `values`, side by side and impossible to read as
entries. Two methods fix that: a dictionary is its entries, and an
`AbstractIndices` — which is its own key set — is its members.
"""
module NarcissusDictionariesExt

using Dictionaries: AbstractDictionary, AbstractIndices
using Narcissus: Narcissus, Component, Semantic

Narcissus.has_semantic_view(::AbstractDictionary) = true

# ── Dictionaries: entries, keyed exactly as a `Dict`'s are ───────────

Narcissus.components(::Semantic, d::AbstractDictionary) =
    (Narcissus._entry_component(k, v) for (k, v) in pairs(d))
Narcissus.component_count(::Semantic, d::AbstractDictionary) = length(d)

# ── Indices: a set whose members are the keys ────────────────────────
#
# `i[x]` on an `AbstractIndices` hands back `x` itself, so the entry view above
# would fill the tree with `:a => :a`. The members are the content, and the
# path that reaches one is positional — the same shape `Set` gets — while the
# key stays the member, which is what anyone reading the row is looking for.

Narcissus.components(::Semantic, i::AbstractIndices) = (
    Component(Narcissus._saferepr(v), "collect({})[$n]", v; kind = :key) for
    (n, v) in enumerate(i)
)
Narcissus.component_count(::Semantic, i::AbstractIndices) = length(i)

end
