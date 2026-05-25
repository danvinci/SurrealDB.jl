module SurrealDB

using Base64
using JSON
using HTTP
using StructTypes
using Tables
using Dates
using UUIDs

# Dependencies for embedded mode (loaded lazily)
# using Libdl - already in stdlib

# --- Core exports ---
export AbstractConnection, RemoteConnection, EmbeddedConnection
export SurrealClient
export connect, close!, status, events
export signin!, signup!, authenticate!, invalidate!, refresh!, tokens, Tokens
export use!, info, version, health, ping
export query, query_verbose, query_table, query_one, create, select, update, delete, insert, upsert, merge
export QueryStatement, isok, iserr
export relate, insert_relation
export patch, patch_add, patch_remove, patch_replace
export run
export let!, unset!
export live, kill!
export begin!, commit!, cancel!
export attach!, detach!, sessions
export SurrealSession
export export_db, import_db
export libsurreal_load!, SurrealThing
export to_table, to_metagraph

# --- Types ---
export ConnectionStatus, STATUS_DISCONNECTED, STATUS_CONNECTING, STATUS_CONNECTED, STATUS_RECONNECTING
export LifecycleEvent, AbstractSurrealLogger, NullLogger, FnLogger
export RecordID, StringRecordID, Table, SurrealValue
export @rid_str
export RootAuth, NamespaceAuth, ScopedAuth, JwtAuth
export Relationship, LiveSubscription, LiveNotification

# --- CBOR wire-format types (re-exported from SurrealDB.SurrealTypes) ---
export SurrealDecimal, SurrealDateTime, SurrealDuration, SurrealFile
export SurrealRange, BoundIncluded, BoundExcluded
export GeometryPoint, GeometryLine, GeometryPolygon
export GeometryMultiPoint, GeometryMultiLine, GeometryMultiPolygon, GeometryCollection

# --- Errors ---
export SurrealError, RPCError, ConnectionError
export ServerError, QueryError, ValidationError, ConfigurationError, ThrownError,
       SerializationError, NotAllowedError, NotFoundError, AlreadyExistsError, InternalError
export EmbeddedFFIError, ConnectionUnavailableError, UnsupportedEngineError, UnsupportedFeatureError, UnsupportedVersionError, UnexpectedResponseError

# --- Implementation modules ---

# SurrealTypes: typed wire-format values (RecordID, Table, Surreal*, Geometry*).
# Owned at the parent level so codec submodules (SurrealCBOR today, future
# JSON-typed) extend `encode` on these types without piracy. Substrate-isolated:
# stdlib-only deps, no upward imports.
include("types/SurrealTypes.jl")
using .SurrealTypes: RecordID, StringRecordID, Table, @rid_str,
    SurrealDecimal, SurrealDateTime, SurrealDuration, SurrealFile,
    SurrealRange, BoundIncluded, BoundExcluded,
    GeometryPoint, GeometryLine, GeometryPolygon,
    GeometryMultiPoint, GeometryMultiLine, GeometryMultiPolygon,
    GeometryCollection

# SurrealCBOR: substrate-isolated CBOR codec submodule. Stdlib-only deps plus
# the sibling SurrealTypes import for wire-format type definitions. No upward
# imports into SurrealDB.* — designed for clean extraction as a standalone
# package later. Access via SurrealDB.SurrealCBOR.*.
include("cbor/SurrealCBOR.jl")

include("errors.jl")
include("types.jl")
include("connection.jl")
include("wire.jl")
include("transport_ws.jl")
include("transport_http.jl")
include("auth.jl")
include("methods.jl")
include("session.jl")
include("live.jl")

# --- Embedded submodule (FFI cluster) ---
# Wraps ffi_types + libsurreal + embedded. Internal helpers stay scoped here;
# user-facing symbols (EmbeddedConnection, libsurreal_load!) are re-imported
# below. Functions and types referenced from tests (julia_to_surreal_value,
# SurrealValue/SR_*/etc. that live in types.jl, EmbeddedFFIError) are imported
# back into SurrealDB so existing call paths keep working.
module Embedded

# Bring the parent module into scope so embedded.jl can extend SurrealDB-level
# stub functions (e.g. `function SurrealDB._close_backend!(::EmbeddedConnection)`)
# across the module boundary.
import ..SurrealDB
using ..SurrealDB:
    AbstractConnection, LiveSubscription, RecordID,
    SurrealValue, SurrealValueKind,
    SR_NONE, SR_NULL, SR_BOOL, SR_INT, SR_FLOAT, SR_DECIMAL,
    SR_STRING, SR_DATETIME, SR_DURATION, SR_UUID, SR_ARRAY,
    SR_OBJECT, SR_BYTES, SR_THING, SR_GEOMETRY,
    ConnectionError, EmbeddedFFIError,
    LifecycleEvent,
    # Stub functions defined in connection.jl/live.jl whose methods are
    # added below for EmbeddedConnection. Importing the names into Embedded
    # lets internal Embedded code (e.g. `_connect_embedded!(conn, url)` from
    # `embedded_connect()`) resolve to the parent's stub binding so dispatch
    # finds the EmbeddedConnection method.
    _connect_embedded!, _close_backend!, _use_backend!,
    _embedded_rpc_call, _poll_embedded_live,
    # Helpers used by embedded.jl from the parent scope
    _to_string, kill!

using JSON
using Dates
using UUIDs

include("ffi_types.jl")
include("libsurreal.jl")
include("embedded.jl")

end # module Embedded

# Re-import Embedded's user/test-facing surface so existing call sites
# (`SurrealDB.julia_to_surreal_value(...)`, tests, etc.) keep working without
# the `Embedded.` qualifier. Internal helpers (`_self_test_layout`,
# `_dict_to_object`, `_julia_to_sr_value`, etc.) stay private to Embedded.
using .Embedded:
    EmbeddedConnection, libsurreal_load!, embedded_connect,
    julia_to_surreal_value, surreal_value_to_julia,
    julia_to_c_value, c_value_to_julia,
    SurrealThing,
    CValueTag, CNumberTag, CGeometryTag, CScope, CAction,
    C_VALUE_NONE, C_VALUE_NULL, C_VALUE_BOOL, C_VALUE_NUMBER,
    C_VALUE_STRAND, C_VALUE_DURATION, C_VALUE_DATETIME, C_VALUE_UUID,
    C_VALUE_ARRAY, C_VALUE_OBJECT, C_VALUE_GEOMETRY, C_VALUE_BYTES,
    C_VALUE_THING,
    C_NUMBER_INT, C_NUMBER_FLOAT, C_NUMBER_DECIMAL,
    C_GEOM_POINT, C_GEOM_LINESTRING, C_GEOM_POLYGON,
    C_GEOM_MULTIPOINT, C_GEOM_MULTILINE, C_GEOM_MULTIPOLYGON,
    C_GEOM_COLLECTION, C_GEOM_UNIMPLEMENTED,
    C_SCOPE_ROOT, C_SCOPE_NAMESPACE, C_SCOPE_DATABASE, C_SCOPE_RECORD,
    C_ACTION_CREATE, C_ACTION_UPDATE, C_ACTION_DELETE,
    C_ACTION_KILLED, C_ACTION_UNIMPLEMENTED

# `LibSurreal` is the bare ccall-wrapper module; tests reference it as
# `SurrealDB.LibSurreal.is_loaded()`. Re-bind under the same path.
const LibSurreal = Embedded.LibSurreal

"""
    to_metagraph(vertices, edges; ...)
    to_metagraph(client::SurrealClient, vertices_query::String, edges_query::String; ...)

Materialize query results into a `MetaGraphsNext.MetaGraph` (with vertex
labels = record-id strings, vertex/edge data = field Dicts). Method bodies
live in the `SurrealDBMetaGraphsNextExt` Pkg extension, loaded automatically
by Julia 1.9+ when the user has `MetaGraphsNext` and `Graphs` in their
environment.

If the extension isn't loaded, calls throw a clear error pointing the user
at the right install command.
"""
function to_metagraph(args...; kwargs...)
    throw(UnsupportedFeatureError(:to_metagraph,
        Symbol("Pkg-extension-not-loaded: install MetaGraphsNext and Graphs to enable")))
end

end # module SurrealDB
