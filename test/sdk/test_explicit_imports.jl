# ExplicitImports.jl lint pass — catches future import-discipline drift.
#
# Three checks run against SurrealDB + every analyzable submodule:
#   - implicit-imports: every `using` line must enumerate names explicitly
#   - owner-canonicality: explicit imports must come from the owning module
#   - no-stale-explicit-imports: imports must actually be used
#
# The 42 names in `_EMBEDDED_REEXPORTS` are deliberately imported from the
# Embedded submodule into SurrealDB so callers (and tests) can drop the
# `Embedded.` qualifier — `SurrealDB.julia_to_surreal_value(...)` reads
# cleaner than `SurrealDB.Embedded.julia_to_surreal_value(...)`. They appear
# stale to ExplicitImports because nothing in SurrealDB's own body uses them
# unqualified. The ignore list preserves the convention without losing the
# drift-detection on every OTHER import.

using SurrealDB
using ExplicitImports
using Test

# The Embedded submodule's user/test-facing surface re-exposed under
# SurrealDB.NAME for ergonomics. Add a name here only when adding a new
# Embedded export that should appear unqualified at the SurrealDB level.
const _EMBEDDED_REEXPORTS = (
    :EmbeddedConnection, :libsurreal_load!, :embedded_connect,
    :julia_to_surreal_value, :surreal_value_to_julia,
    :julia_to_c_value, :c_value_to_julia,
    :SurrealThing,
    :CValueTag, :CNumberTag, :CGeometryTag, :CScope, :CAction,
    :C_VALUE_NONE, :C_VALUE_NULL, :C_VALUE_BOOL, :C_VALUE_NUMBER,
    :C_VALUE_STRAND, :C_VALUE_DURATION, :C_VALUE_DATETIME, :C_VALUE_UUID,
    :C_VALUE_ARRAY, :C_VALUE_OBJECT, :C_VALUE_GEOMETRY, :C_VALUE_BYTES,
    :C_VALUE_THING,
    :C_NUMBER_INT, :C_NUMBER_FLOAT, :C_NUMBER_DECIMAL,
    :C_GEOM_POINT, :C_GEOM_LINESTRING, :C_GEOM_POLYGON,
    :C_GEOM_MULTIPOINT, :C_GEOM_MULTILINE, :C_GEOM_MULTIPOLYGON,
    :C_GEOM_COLLECTION, :C_GEOM_UNIMPLEMENTED,
    :C_SCOPE_ROOT, :C_SCOPE_NAMESPACE, :C_SCOPE_DATABASE, :C_SCOPE_RECORD,
    :C_ACTION_CREATE, :C_ACTION_UPDATE, :C_ACTION_DELETE,
    :C_ACTION_KILLED, :C_ACTION_UNIMPLEMENTED,
)

const _LINTED_MODULES = (
    SurrealDB,
    SurrealDB.SurrealCBOR,
    SurrealDB.SurrealTypes,
    SurrealDB.Embedded,
    SurrealDB.Embedded.LibSurreal,
)

# Submodules have no `pathof` of their own, so ExplicitImports can't locate the
# source that defines them and throws FileNotFoundException (julia ≤1.10; newer
# julia happens to mask it). Passing the package's entry file lets it resolve
# every submodule from the include tree — robust across julia versions.
const _PKGFILE = pathof(SurrealDB)

@testset "no implicit imports" begin
    # Every `using Foo` line names what it brings in. Catches the case where
    # adding a new `using Foo` quietly pulls in a name the rest of the file
    # accidentally relies on.
    for m in _LINTED_MODULES
        @test isnothing(ExplicitImports.check_no_implicit_imports(m, _PKGFILE))
    end
end

@testset "explicit imports come from owners" begin
    # Every explicit `using Foo: bar` must have Foo as the canonical owner of
    # `bar` — not a re-exporter. Catches the case where a peer module changes
    # what it re-exports and our import silently follows along.
    for m in _LINTED_MODULES
        @test isnothing(ExplicitImports.check_all_explicit_imports_via_owners(m, _PKGFILE))
    end
end

@testset "no stale explicit imports" begin
    # Catches imports that no longer have any use site. The SurrealDB-level
    # check ignores the `_EMBEDDED_REEXPORTS` re-export block (see top of
    # file for rationale).
    @test isnothing(ExplicitImports.check_no_stale_explicit_imports(SurrealDB, _PKGFILE;
        ignore=_EMBEDDED_REEXPORTS))
    @test isnothing(ExplicitImports.check_no_stale_explicit_imports(SurrealDB.SurrealCBOR, _PKGFILE))
    @test isnothing(ExplicitImports.check_no_stale_explicit_imports(SurrealDB.SurrealTypes, _PKGFILE))
    @test isnothing(ExplicitImports.check_no_stale_explicit_imports(SurrealDB.Embedded, _PKGFILE))
    @test isnothing(ExplicitImports.check_no_stale_explicit_imports(SurrealDB.Embedded.LibSurreal, _PKGFILE))
end
