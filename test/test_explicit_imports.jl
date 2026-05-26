# ExplicitImports.jl lint pass — catches future import-discipline drift.
#
# Today only the "imports via owners" check is asserted clean; the two
# stricter checks document known gaps (commented below). The drift-detector
# value is in the "via owners" assertion — if a future edit imports a symbol
# via a re-exporter rather than the canonical owner, this test catches it
# before the implicit re-export contract breaks.

using SurrealDB
using ExplicitImports
using Test

@testset "explicit imports come from owners" begin
    # Every explicit `using Foo: bar` must have Foo as the canonical owner of
    # `bar` — not a re-exporter. Catches the case where a peer module changes
    # what it re-exports and our import silently follows along.
    @test isnothing(ExplicitImports.check_all_explicit_imports_via_owners(SurrealDB))
end

# Two stricter checks are intentionally NOT asserted yet:
#
#   - `check_no_implicit_imports(SurrealDB)` — src/SurrealDB.jl uses bare
#     `using Foo` for Base64, Dates, HTTP, JSON, StructTypes, Tables, UUIDs.
#     Converting each to an explicit name list is mechanical but is its own
#     audit pass; enable once that lands.
#
#   - `check_no_stale_explicit_imports(SurrealDB)` — the `using .Embedded: ...`
#     block at the bottom of SurrealDB.jl re-binds ~42 submodule symbols at
#     the parent level so test sites can write `SurrealDB.C_VALUE_NONE` in
#     place of `SurrealDB.Embedded.C_VALUE_NONE`. ExplicitImports rightly
#     flags these as "stale" (imported but unused in SurrealDB's own body) —
#     but they're load-bearing for the convention. Either pin the ignore list
#     or rework the re-export pattern via `Base.getproperty(::Module, ...)`
#     before enabling.
