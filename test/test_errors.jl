# Unit tests for D1 kind-tagged ServerError dispatch.
# No server required — exercises _parse_rpc_error / _parse_query_error against
# synthetic payloads that mirror surrealdb.js wire format.

using SurrealDB
using SurrealDB: _parse_rpc_error, _parse_query_error, _create_server_error,
    _resolve_kind, _CODE_TO_KIND
using Test

@testset "kind dispatch (factory)" begin
    # Every kind string maps to its concrete subclass.
    @test _create_server_error("Validation", "x") isa ValidationError
    @test _create_server_error("Configuration", "x") isa ConfigurationError
    @test _create_server_error("Thrown", "x") isa ThrownError
    @test _create_server_error("Query", "x") isa QueryError
    @test _create_server_error("Serialization", "x") isa SerializationError
    @test _create_server_error("NotAllowed", "x") isa NotAllowedError
    @test _create_server_error("NotFound", "x") isa NotFoundError
    @test _create_server_error("AlreadyExists", "x") isa AlreadyExistsError
    @test _create_server_error("Internal", "x") isa InternalError

    # Unknown kinds fall through to InternalError so callers can still
    # `catch e::ServerError` uniformly without losing the message.
    fall = _create_server_error("FutureKindWeDontKnowYet", "msg")
    @test fall isa InternalError
    @test fall isa ServerError
    @test fall.message == "msg"
end

@testset "_resolve_kind" begin
    @test _resolve_kind("Query", nothing) == "Query"
    @test _resolve_kind("", -32003) == "Query"           # empty string → falls to code
    @test _resolve_kind(nothing, -32602) == "NotAllowed"
    @test _resolve_kind(nothing, -32605) == "Configuration"
    @test _resolve_kind(nothing, -32999) == "Internal"   # unknown code
    @test _resolve_kind(nothing, nothing) == "Internal"  # neither
end

@testset "_parse_rpc_error: kind path" begin
    e = _parse_rpc_error(Dict(
        "code" => 0, "message" => "denied",
        "kind" => "NotAllowed",
        "details" => Dict("kind" => "Auth",
                          "details" => Dict("kind" => "TokenExpired")),
    ))
    @test e isa NotAllowedError
    @test e.is_token_expired == true
    @test e.is_invalid_auth == false
    @test e.message == "denied"

    e2 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "auth bad",
        "kind" => "NotAllowed",
        "details" => Dict("kind" => "Auth",
                          "details" => Dict("kind" => "InvalidAuth")),
    ))
    @test e2 isa NotAllowedError
    @test e2.is_invalid_auth == true
    @test e2.is_token_expired == false

    e3 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "field missing",
        "kind" => "Validation",
        "details" => Dict("kind" => "Parse", "parameter_name" => "x"),
    ))
    @test e3 isa ValidationError
    @test e3.is_parse_error == true
    @test e3.parameter_name == "x"

    e4 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "no such record",
        "kind" => "NotFound",
        "details" => Dict("table_name" => "user", "record_id" => "user:alice"),
    ))
    @test e4 isa NotFoundError
    @test e4.table_name == "user"
    @test e4.record_id == "user:alice"

    e5 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "dup",
        "kind" => "AlreadyExists",
        "details" => Dict("table_name" => "user", "record_id" => "user:bob"),
    ))
    @test e5 isa AlreadyExistsError
    @test e5.table_name == "user"
    @test e5.record_id == "user:bob"

    e6 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "thrown",
        "kind" => "Thrown",
    ))
    @test e6 isa ThrownError
    @test e6.message == "thrown"

    e7 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "ser",
        "kind" => "Serialization",
        "details" => Dict("kind" => "Deserialization"),
    ))
    @test e7 isa SerializationError
    @test e7.is_deserialization == true

    e8 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "live not supported",
        "kind" => "Configuration",
        "details" => Dict("kind" => "LiveQueryNotSupported"),
    ))
    @test e8 isa ConfigurationError
    @test e8.is_live_query_not_supported == true

    e9 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "timed out",
        "kind" => "Query",
        "details" => Dict("kind" => "TimedOut"),
    ))
    @test e9 isa QueryError
    @test e9.is_timed_out == true
    @test e9.is_cancelled == false

    e10 = _parse_rpc_error(Dict(
        "code" => 0, "message" => "cancelled",
        "kind" => "Query",
        "details" => Dict("kind" => "Cancelled"),
    ))
    @test e10 isa QueryError
    @test e10.is_cancelled == true
end

@testset "_parse_rpc_error: legacy code-only path" begin
    # No kind field — uses CODE_TO_KIND.
    e = _parse_rpc_error(Dict("code" => -32003, "message" => "bad query"))
    @test e isa QueryError
    @test e.message == "bad query"

    e2 = _parse_rpc_error(Dict("code" => -32602, "message" => "denied"))
    @test e2 isa NotAllowedError

    e3 = _parse_rpc_error(Dict("code" => -32601, "message" => "no method"))
    @test e3 isa NotFoundError

    e4 = _parse_rpc_error(Dict("code" => -32007, "message" => "ser"))
    @test e4 isa SerializationError

    e5 = _parse_rpc_error(Dict("code" => -32606, "message" => "config"))
    @test e5 isa ConfigurationError

    e6 = _parse_rpc_error(Dict("code" => -32006, "message" => "thrown"))
    @test e6 isa ThrownError
end

@testset "_parse_rpc_error: fallback to RPCError" begin
    # Unknown code, no kind — preserve pre-D1 RPCError contract for
    # transport/unknown-code failures.
    e = _parse_rpc_error(Dict("code" => -1, "message" => "transport blip"))
    @test e isa RPCError
    @test e.code == -1
    @test e.message == "transport blip"

    # Empty / no kind, weird code (1234 is not in CODE_TO_KIND).
    e2 = _parse_rpc_error(Dict("code" => 1234, "message" => "huh"))
    @test e2 isa RPCError
    @test e2.code == 1234
end

@testset "_parse_query_error: query result ERR" begin
    # Standard query error with kind.
    e = _parse_query_error(Dict(
        "status" => "ERR", "time" => "1ms",
        "result" => "x is missing",
        "kind" => "NotFound",
        "details" => Dict("table_name" => "user"),
    ))
    @test e isa NotFoundError
    @test e.table_name == "user"
    @test e.message == "x is missing"

    # Legacy: no kind, just message in result. Stays a flat QueryError.
    e2 = _parse_query_error(Dict(
        "status" => "ERR", "time" => "1ms",
        "result" => "raw error string",
    ))
    @test e2 isa QueryError
    @test e2.message == "raw error string"

    # Double-wrapped details: server emits {kind: X, details: {kind: X, details: {...}}}.
    # Inner details should be unwrapped before predicate extraction.
    e3 = _parse_query_error(Dict(
        "status" => "ERR", "time" => "1ms",
        "result" => "auth fail",
        "kind" => "NotAllowed",
        "details" => Dict(
            "kind" => "NotAllowed",
            "details" => Dict("kind" => "Auth",
                              "details" => Dict("kind" => "TokenExpired")),
        ),
    ))
    @test e3 isa NotAllowedError
    @test e3.is_token_expired == true

    # Result missing — falls back to a sensible default.
    e4 = _parse_query_error(Dict("status" => "ERR", "time" => "1ms"))
    @test e4 isa QueryError
    @test e4.message == "unknown error"
end

@testset "all kind-tagged errors are ServerError subtypes" begin
    # Catching ServerError must catch every concrete subclass — the abstract
    # supertype is the load-bearing contract for kind-aware handlers.
    for k in ("Validation", "Configuration", "Thrown", "Query", "Serialization",
              "NotAllowed", "NotFound", "AlreadyExists", "Internal", "Unknown")
        e = _create_server_error(k, "msg")
        @test e isa ServerError
        @test e isa SurrealDBError
        @test e isa SurrealError   # alias still works
    end
end
