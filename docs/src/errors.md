# Errors

```
SurrealError
├── ServerError              (server-reported, kind-tagged)
│   ├── ValidationError          .parameter_name, .is_parse_error
│   ├── ConfigurationError       .is_live_query_not_supported
│   ├── ThrownError
│   ├── QueryError               .is_timed_out, .is_cancelled
│   ├── SerializationError       .is_deserialization
│   ├── NotAllowedError          .is_token_expired, .is_invalid_auth, .method_name
│   ├── NotFoundError            .table_name, .record_id, .namespace_name
│   ├── AlreadyExistsError       .table_name, .record_id
│   └── InternalError
├── RPCError                     (legacy / unknown JSON-RPC code)
├── ConnectionError              (transport-level: drop, timeout)
├── ConnectionUnavailableError
├── UnsupportedEngineError       .scheme
├── UnsupportedFeatureError      .feature, .transport
├── UnsupportedVersionError      .server_version, .minimum, .maximum
├── UnexpectedResponseError
└── EmbeddedFFIError             .op, .message
```

Catch a specific subtype for branch logic, or catch `ServerError` to handle any server-side failure uniformly:

```julia
try
    SurrealDB.create(db, "user", Dict(...))
catch e::SurrealDB.AlreadyExistsError
    @info "already exists" table=e.table_name record=e.record_id
catch e::SurrealDB.ServerError
    @warn "server failure" e
end
```

The wire-format `kind` field maps to the Julia subtype.
Older servers that emit only a JSON-RPC `code` go through a code-to-kind table.
