# Public API stability snapshot.
#
# Asserts the exported symbol list matches a frozen baseline. Any addition
# or removal triggers a test failure: the fix is to update EXPECTED here in
# the same commit that changes the public surface, making the change show
# up in code review.
#
# This catches accidental API churn (auto-export from `using` an internal
# symbol that grew an `export` line, removal of a symbol someone external
# might depend on) without prescribing what the API should be.

using SurrealDB
using Test

const EXPECTED_EXPORTS = Set([
    # Module
    :SurrealDB,

    # Connection status enum
    :ConnectionStatus,
    :STATUS_DISCONNECTED, :STATUS_CONNECTING, :STATUS_CONNECTED, :STATUS_RECONNECTING,

    # Lifecycle observability
    :LifecycleEvent, :AbstractSurrealLogger, :NullLogger, :FnLogger,

    # Core types
    :AbstractConnection, :RemoteConnection, :EmbeddedConnection,
    :SurrealClient, :SurrealSession, :SurrealTransaction,
    :RecordID, :StringRecordID, :Table, :SurrealValue, :Relationship, :LiveSubscription, :LiveNotification,
    Symbol("@rid_str"),

    # Auth
    :RootAuth, :NamespaceAuth, :ScopedAuth, :JwtAuth, :Tokens,

    # Connection lifecycle
    :connect, :close!, :status, :events,

    # Auth methods
    :signin!, :signup!, :authenticate!, :invalidate!, :refresh!, :tokens,

    # Database scope
    :use!, :info, :version, :health, :ping,

    # Query / CRUD
    :query, :query_verbose, :query_table, :query_one,
    :QueryStatement, :isok, :iserr,
    :create, :select, :update, :delete, :insert, :upsert, :merge,
    :relate, :insert_relation,
    :patch, :patch_add, :patch_remove, :patch_replace,
    :run,
    :let!, :unset!,

    # Live queries
    :live, :kill!,

    # Transactions
    :begin!, :commit!, :cancel!,

    # Sessions
    :attach!, :detach!, :sessions,

    # Import / export
    :export_db, :import_db,

    # Embedded
    :libsurreal_load!, :SurrealThing,

    # Tables / extensions
    :to_table, :to_metagraph,

    # Errors
    :SurrealError, :RPCError, :ConnectionError,
    :ServerError, :QueryError, :ValidationError, :ConfigurationError,
    :ThrownError, :SerializationError, :NotAllowedError, :NotFoundError,
    :AlreadyExistsError, :InternalError,
    :EmbeddedFFIError, :ConnectionUnavailableError, :UnsupportedEngineError,
    :UnsupportedFeatureError, :UnsupportedVersionError, :UnexpectedResponseError,

    # CBOR wire-format types (re-exported from SurrealDB.SurrealCBOR)
    :SurrealDecimal, :SurrealDateTime, :SurrealDuration, :SurrealFile,
    :SurrealRange, :BoundIncluded, :BoundExcluded,
    :GeometryPoint, :GeometryLine, :GeometryPolygon,
    :GeometryMultiPoint, :GeometryMultiLine, :GeometryMultiPolygon, :GeometryCollection,
])

@testset "public API surface is stable" begin
    actual = Set(names(SurrealDB))
    added = setdiff(actual, EXPECTED_EXPORTS)
    removed = setdiff(EXPECTED_EXPORTS, actual)

    if !isempty(added)
        @info "new exports detected — update EXPECTED_EXPORTS or remove the export" added
    end
    if !isempty(removed)
        @info "exports removed — update EXPECTED_EXPORTS or restore the export" removed
    end

    @test isempty(added)
    @test isempty(removed)
    @test actual == EXPECTED_EXPORTS
end
