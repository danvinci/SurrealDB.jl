# Error type hierarchy for SurrealDB.jl

"""
    SurrealError

Abstract base type for all SurrealDB SDK errors.
"""
abstract type SurrealError <: Exception end

"""
    RPCError(code, message)

Represents a JSON-RPC error returned by the SurrealDB server.
This includes transport errors, protocol errors, and server-side failures.

Fields:
- `code::Int`: JSON-RPC numeric error code
- `message::String`: Human-readable error message from the server
"""
struct RPCError <: SurrealError
    code::Int
    message::String
end

Base.showerror(io::IO, e::RPCError) = print(io, "RPCError($(e.code)): $(e.message)")

"""
    ServerError <: SurrealError

Abstract supertype for errors that originated server-side (i.e. the SurrealDB
engine reported the failure). Mirrors the kind-tagged `ServerError` hierarchy
in surrealdb.js and surrealdb.py — concrete subtypes correspond to the
`kind` field of the wire-protocol error payload.

Concrete subtypes:
- [`ValidationError`](@ref) — request validation failed
- [`ConfigurationError`](@ref) — database/namespace/feature misconfiguration
- [`ThrownError`](@ref) — user `THROW` statement
- [`QueryError`](@ref) — SurrealQL parse/execution failure
- [`SerializationError`](@ref) — wire encode/decode failure
- [`NotAllowedError`](@ref) — auth/permission denial
- [`NotFoundError`](@ref) — record/table/namespace not found
- [`AlreadyExistsError`](@ref) — record already exists
- [`InternalError`](@ref) — server-side bug

Catch `ServerError` to handle any server-side failure uniformly; catch a
specific subtype for kind-aware handling.
"""
abstract type ServerError <: SurrealError end

"""
    QueryError(message)

A SurrealQL parse or execution failure. Subtype of [`ServerError`](@ref).

Fields:
- `message::String`: Error message describing the query failure
- `is_timed_out::Bool`: `true` when the server reports the query timed out
- `is_cancelled::Bool`: `true` when the query was cancelled mid-execution

Bare-message constructor is supported for backward compat:
`QueryError(msg)` ≡ `QueryError(msg, false, false)`.
"""
struct QueryError <: ServerError
    message::String
    is_timed_out::Bool
    is_cancelled::Bool
end

QueryError(message::AbstractString) = QueryError(String(message), false, false)

Base.showerror(io::IO, e::QueryError) = print(io, "QueryError: $(e.message)")

"""
    ValidationError(message; parameter_name=nothing, is_parse_error=false)

Request validation failed before the query was executed. Subtype of [`ServerError`](@ref).
"""
struct ValidationError <: ServerError
    message::String
    parameter_name::Union{String, Nothing}
    is_parse_error::Bool
end

ValidationError(message::AbstractString; parameter_name=nothing, is_parse_error::Bool=false) =
    ValidationError(String(message),
                    parameter_name === nothing ? nothing : String(parameter_name),
                    is_parse_error)

Base.showerror(io::IO, e::ValidationError) = print(io, "ValidationError: ", e.message)

"""
    ConfigurationError(message; is_live_query_not_supported=false)

Database/namespace/feature configuration prevents the operation. Subtype of [`ServerError`](@ref).
"""
struct ConfigurationError <: ServerError
    message::String
    is_live_query_not_supported::Bool
end

ConfigurationError(message::AbstractString; is_live_query_not_supported::Bool=false) =
    ConfigurationError(String(message), is_live_query_not_supported)

Base.showerror(io::IO, e::ConfigurationError) = print(io, "ConfigurationError: ", e.message)

"""
    ThrownError(message)

Result of an explicit user `THROW` statement in SurrealQL. Subtype of [`ServerError`](@ref).
"""
struct ThrownError <: ServerError
    message::String
end

Base.showerror(io::IO, e::ThrownError) = print(io, "ThrownError: ", e.message)

"""
    SerializationError(message; is_deserialization=false)

Wire-format encode/decode failure. Subtype of [`ServerError`](@ref).
"""
struct SerializationError <: ServerError
    message::String
    is_deserialization::Bool
end

SerializationError(message::AbstractString; is_deserialization::Bool=false) =
    SerializationError(String(message), is_deserialization)

Base.showerror(io::IO, e::SerializationError) = print(io, "SerializationError: ", e.message)

"""
    NotAllowedError(message; is_token_expired=false, is_invalid_auth=false, method_name=nothing)

Authentication or authorization denied the request. Subtype of [`ServerError`](@ref).
"""
struct NotAllowedError <: ServerError
    message::String
    is_token_expired::Bool
    is_invalid_auth::Bool
    method_name::Union{String, Nothing}
end

NotAllowedError(message::AbstractString;
                is_token_expired::Bool=false,
                is_invalid_auth::Bool=false,
                method_name=nothing) =
    NotAllowedError(String(message), is_token_expired, is_invalid_auth,
                    method_name === nothing ? nothing : String(method_name))

Base.showerror(io::IO, e::NotAllowedError) = print(io, "NotAllowedError: ", e.message)

"""
    NotFoundError(message; table_name=nothing, record_id=nothing, namespace_name=nothing)

A referenced record, table, or namespace does not exist. Subtype of [`ServerError`](@ref).
"""
struct NotFoundError <: ServerError
    message::String
    table_name::Union{String, Nothing}
    record_id::Union{String, Nothing}
    namespace_name::Union{String, Nothing}
end

NotFoundError(message::AbstractString;
              table_name=nothing, record_id=nothing, namespace_name=nothing) =
    NotFoundError(String(message),
                  table_name === nothing ? nothing : String(table_name),
                  record_id === nothing ? nothing : String(record_id),
                  namespace_name === nothing ? nothing : String(namespace_name))

Base.showerror(io::IO, e::NotFoundError) = print(io, "NotFoundError: ", e.message)

"""
    AlreadyExistsError(message; table_name=nothing, record_id=nothing)

The target record/table already exists and the operation rejects duplicates.
Subtype of [`ServerError`](@ref).
"""
struct AlreadyExistsError <: ServerError
    message::String
    table_name::Union{String, Nothing}
    record_id::Union{String, Nothing}
end

AlreadyExistsError(message::AbstractString;
                   table_name=nothing, record_id=nothing) =
    AlreadyExistsError(String(message),
                       table_name === nothing ? nothing : String(table_name),
                       record_id === nothing ? nothing : String(record_id))

Base.showerror(io::IO, e::AlreadyExistsError) = print(io, "AlreadyExistsError: ", e.message)

"""
    InternalError(message)

A server-side bug or unexpected condition. Subtype of [`ServerError`](@ref).
"""
struct InternalError <: ServerError
    message::String
end

Base.showerror(io::IO, e::InternalError) = print(io, "InternalError: ", e.message)

"""
    ConnectionError(message, cause)

Represents a connection-level failure (WebSocket disconnect, timeout, etc.).

Fields:
- `message::String`: Description of the connection failure
- `cause::Union{Exception, Nothing}`: Underlying exception that caused the failure, if any
"""
struct ConnectionError <: SurrealError
    message::String
    cause::Union{Exception, Nothing}
end

ConnectionError(message::String) = ConnectionError(message, nothing)

Base.showerror(io::IO, e::ConnectionError) = print(io, "ConnectionError: $(e.message)")

"""
    EmbeddedFFIError(op, message)

A failure originating from the embedded libsurreal FFI layer. Distinct from
[`RPCError`](@ref) (which represents server-side JSON-RPC failures) and
[`ConnectionError`](@ref) (transport-level failures) so callers can distinguish
"libsurreal misbehaved" from "the network blinked."

Fields:
- `op::String`: the FFI operation that failed (e.g. `"sr_patch_add"`, `"_self_test_layout"`)
- `message::String`: error message — either propagated from the C library or describing the layout/lookup mismatch
"""
struct EmbeddedFFIError <: SurrealError
    op::String
    message::String
end

Base.showerror(io::IO, e::EmbeddedFFIError) = print(io, "EmbeddedFFIError(", e.op, "): ", e.message)

# --- D1 partial: canonical SDK-side flat error types ---
#
# These mirror the surrealdb.js + surrealdb.py SDK-side flat siblings that
# don't depend on a kind-tagged ServerError hierarchy. Adding them now avoids
# a breaking change in 0.2 when the full ServerError split lands.

"""
    ConnectionUnavailableError(message="No active connection to the database.")

The client is not connected (or has been closed). Distinct from
[`ConnectionError`](@ref) which represents transport-level failures during
an attempt; this is raised for "no connection at all" scenarios.
"""
struct ConnectionUnavailableError <: SurrealError
    message::String
    ConnectionUnavailableError(message::AbstractString = "No active connection to the database.") = new(String(message))
end

Base.showerror(io::IO, e::ConnectionUnavailableError) = print(io, "ConnectionUnavailableError: ", e.message)

"""
    UnsupportedEngineError(scheme::String)

The URL scheme is not recognised. Mirrors the JS SDK's same-named error.
"""
struct UnsupportedEngineError <: SurrealError
    scheme::String
end

Base.showerror(io::IO, e::UnsupportedEngineError) = print(io, "UnsupportedEngineError: '", e.scheme, "' is not a supported URL scheme. Use ws://, wss://, http://, https://, mem://, or surrealkv://path.")

"""
    UnsupportedFeatureError(feature, transport=nothing)

The requested operation is not supported on the current transport (e.g. live
queries over HTTP). `feature` is a Symbol naming the feature; `transport`
optionally names the transport that lacks support.
"""
struct UnsupportedFeatureError <: SurrealError
    feature::Symbol
    transport::Union{Symbol, Nothing}
    UnsupportedFeatureError(feature::Symbol, transport=nothing) = new(feature, transport)
end

function Base.showerror(io::IO, e::UnsupportedFeatureError)
    print(io, "UnsupportedFeatureError: feature `", e.feature, "` ")
    e.transport === nothing ? print(io, "is not supported.") :
        print(io, "is not supported on the `", e.transport, "` transport.")
end

"""
    UnexpectedResponseError(message)

The server returned a response in an unexpected shape. Used when the wire
format doesn't match any of the documented response variants.
"""
struct UnexpectedResponseError <: SurrealError
    message::String
end

Base.showerror(io::IO, e::UnexpectedResponseError) = print(io, "UnexpectedResponseError: ", e.message)

# --- D1 parser wiring: kind-tagged ServerError dispatch ---
#
# Mirrors surrealdb.js packages/sdk/src/internal/parse-error.ts. Server emits
# wire payloads with a `kind` field naming one of the ServerError subclasses
# (Validation, Query, NotAllowed, etc). When the legacy code-only format is
# used, _CODE_TO_KIND maps JSON-RPC error codes to a kind string. Unknown
# kinds fall through to ServerError (or InternalError) so callers can still
# `catch e::ServerError` uniformly.

const _CODE_TO_KIND = Dict{Int, String}(
    -32700 => "Validation",
    -32600 => "Validation",
    -32601 => "NotFound",
    -32602 => "NotAllowed",
    -32603 => "Validation",
    -32604 => "Configuration",
    -32605 => "Configuration",
    -32606 => "Configuration",
    -32000 => "Internal",
    -32001 => "Internal",   # JS uses "Connection" — no Connection ServerError subclass; fall to Internal
    -32002 => "NotAllowed",
    -32003 => "Query",
    -32004 => "Query",
    -32005 => "Query",
    -32006 => "Thrown",
    -32007 => "Serialization",
    -32008 => "Serialization",
)

function _resolve_kind(kind, code)::String
    if kind isa AbstractString && !isempty(kind)
        return String(kind)
    end
    if code isa Integer
        return get(_CODE_TO_KIND, Int(code), "Internal")
    end
    return "Internal"
end

# Detail extraction: each kind has subclass-specific predicates derived from
# the wire-protocol `details` object. Conservative — only set predicates when
# the corresponding `details.kind` (or scalar field) is present. Unknown
# detail shapes are tolerated; missing fields fall back to defaults.

_detail_kind(details) = (details isa AbstractDict) ? get(details, "kind", nothing) : nothing
_detail_str(details, key) = begin
    if details isa AbstractDict && haskey(details, key)
        v = details[key]
        v === nothing ? nothing : String(v)
    else
        nothing
    end
end

function _make_validation(message::String, details)::ValidationError
    pname = _detail_str(details, "parameter_name")
    if pname === nothing
        pname = _detail_str(details, "parameterName")
    end
    is_parse = _detail_kind(details) == "Parse"
    return ValidationError(message; parameter_name=pname, is_parse_error=is_parse)
end

function _make_configuration(message::String, details)::ConfigurationError
    is_lq = _detail_kind(details) == "LiveQueryNotSupported"
    return ConfigurationError(message; is_live_query_not_supported=is_lq)
end

_make_thrown(message::String, _details) = ThrownError(message)

function _make_query(message::String, details)::QueryError
    dk = _detail_kind(details)
    is_timed = dk == "TimedOut"
    is_cancel = dk == "Cancelled"
    return QueryError(message, is_timed, is_cancel)
end

function _make_serialization(message::String, details)::SerializationError
    is_de = _detail_kind(details) == "Deserialization"
    return SerializationError(message; is_deserialization=is_de)
end

function _make_not_allowed(message::String, details)::NotAllowedError
    # JS predicates: details.kind == "Auth" && details.details.kind == "TokenExpired" / "InvalidAuth"
    is_token_expired = false
    is_invalid_auth = false
    method_name = _detail_str(details, "method_name")
    if method_name === nothing
        method_name = _detail_str(details, "methodName")
    end
    if details isa AbstractDict && get(details, "kind", nothing) == "Auth"
        nested = get(details, "details", nothing)
        nk = _detail_kind(nested)
        is_token_expired = nk == "TokenExpired"
        is_invalid_auth = nk == "InvalidAuth"
    end
    return NotAllowedError(message;
                           is_token_expired=is_token_expired,
                           is_invalid_auth=is_invalid_auth,
                           method_name=method_name)
end

function _make_not_found(message::String, details)::NotFoundError
    table_name = _detail_str(details, "table_name")
    if table_name === nothing
        table_name = _detail_str(details, "tableName")
    end
    record_id = _detail_str(details, "record_id")
    if record_id === nothing
        record_id = _detail_str(details, "recordId")
    end
    namespace_name = _detail_str(details, "namespace_name")
    if namespace_name === nothing
        namespace_name = _detail_str(details, "namespaceName")
    end
    return NotFoundError(message;
                         table_name=table_name,
                         record_id=record_id,
                         namespace_name=namespace_name)
end

function _make_already_exists(message::String, details)::AlreadyExistsError
    table_name = _detail_str(details, "table_name")
    if table_name === nothing
        table_name = _detail_str(details, "tableName")
    end
    record_id = _detail_str(details, "record_id")
    if record_id === nothing
        record_id = _detail_str(details, "recordId")
    end
    return AlreadyExistsError(message; table_name=table_name, record_id=record_id)
end

_make_internal(message::String, _details) = InternalError(message)

"""
    _create_server_error(kind, message; details=nothing)

Factory dispatching on `kind` to the matching [`ServerError`](@ref) subclass.
Unknown kinds return a plain [`InternalError`](@ref) so callers can still
catch `ServerError` uniformly. Mirrors `createServerError` in surrealdb.js.
"""
function _create_server_error(kind::AbstractString, message::AbstractString; details=nothing)
    msg = String(message)
    k = String(kind)
    if k == "Validation"
        return _make_validation(msg, details)
    elseif k == "Configuration"
        return _make_configuration(msg, details)
    elseif k == "Thrown"
        return _make_thrown(msg, details)
    elseif k == "Query"
        return _make_query(msg, details)
    elseif k == "Serialization"
        return _make_serialization(msg, details)
    elseif k == "NotAllowed"
        return _make_not_allowed(msg, details)
    elseif k == "NotFound"
        return _make_not_found(msg, details)
    elseif k == "AlreadyExists"
        return _make_already_exists(msg, details)
    else
        # "Internal" + unknown kinds
        return _make_internal(msg, details)
    end
end

"""
    _parse_rpc_error(err::AbstractDict)

Convert a JSON-RPC error envelope (`{code, message, kind?, details?}`) into
a typed [`ServerError`](@ref). Falls back to [`RPCError`](@ref) when the
payload has neither a `kind` field nor a recognized `code` (preserves the
pre-D1 contract for transport-level / -1 / unknown-code failures).
"""
function _parse_rpc_error(err::AbstractDict)
    code_raw = get(err, "code", nothing)
    code = code_raw isa Integer ? Int(code_raw) : nothing
    msg_raw = get(err, "message", "")
    message = msg_raw isa AbstractString ? String(msg_raw) : string(msg_raw)
    kind_raw = get(err, "kind", nothing)
    details = get(err, "details", nothing)

    has_kind = kind_raw isa AbstractString && !isempty(kind_raw)
    known_code = code !== nothing && haskey(_CODE_TO_KIND, code)

    if has_kind || known_code
        kind = _resolve_kind(kind_raw, code)
        return _create_server_error(kind, message; details=details)
    end

    # Fallback: legacy / transport-level. Preserve RPCError contract.
    return RPCError(code === nothing ? -1 : code, message)
end

"""
    _parse_query_error(item::AbstractDict)

Convert a query result item (`{status: "ERR", time, result, kind?, details?}`)
into a typed [`ServerError`](@ref). The error message lives in `result`
(not `message`) for query-result errors. Falls back to a flat
[`QueryError`](@ref) when neither `kind` nor structured details are present
— matches pre-D1 behavior on legacy server payloads.
"""
function _parse_query_error(item::AbstractDict)
    msg_raw = get(item, "result", "unknown error")
    message = msg_raw isa AbstractString ? String(msg_raw) : string(msg_raw)
    kind_raw = get(item, "kind", nothing)
    details = get(item, "details", nothing)

    # Unwrap double-wrapped details: server's query-result path may emit
    # `details = {kind: <same>, details: {...}}` — when details.kind matches
    # the top-level kind, the inner details object is what we want. Mirrors
    # parseQueryError in surrealdb.js.
    if details isa AbstractDict && kind_raw isa AbstractString &&
       get(details, "kind", nothing) == kind_raw &&
       haskey(details, "details") && details["details"] isa AbstractDict
        details = details["details"]
    end

    has_kind = kind_raw isa AbstractString && !isempty(kind_raw)
    if has_kind
        return _create_server_error(String(kind_raw), message; details=details)
    end

    # Legacy server: just a message, no kind. Stay with the flat QueryError.
    return QueryError(message)
end
