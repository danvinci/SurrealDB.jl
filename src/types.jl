# Core data types for SurrealDB.jl

# --- RecordID ---

"""
    RecordID(table, id)

Represents a SurrealDB record identifier consisting of a table name and an ID.

# Examples
```julia
RecordID("user", "abc123")           # table + string id
RecordID("user", 42)                 # table + integer id
RecordID("user:abc123")              # parse from string
```
"""
struct RecordID
    table::String
    id::Any
end

function RecordID(s::String)
    parts = split(s, ":"; limit=2)
    if length(parts) != 2
        throw(ArgumentError("Invalid RecordID string: `$s`. Expected format `table:id`"))
    end
    return RecordID(parts[1], parts[2])
end

Base.string(r::RecordID) = "$(r.table):$(r.id)"
Base.show(io::IO, r::RecordID) = print(io, "RecordID(\"$(r.table):$(r.id)\")")
Base.print(io::IO, r::RecordID) = print(io, r.table, ":", r.id)

# --- Table ---

"""
    Table(name)

Represents a SurrealDB table name. Wraps a String for clarity in the API.

# Examples
```julia
Table("stream")
```
"""
struct Table
    name::String
end

Base.string(t::Table) = t.name
Base.show(io::IO, t::Table) = print(io, "Table(\"$(t.name)\")")

# --- SurrealValue ---

@enum SurrealValueKind begin
    SR_NONE
    SR_NULL
    SR_BOOL
    SR_INT
    SR_FLOAT
    SR_DECIMAL
    SR_STRING
    SR_DATETIME
    SR_DURATION
    SR_UUID
    SR_ARRAY
    SR_OBJECT
    SR_BYTES
    SR_THING
    SR_GEOMETRY
end

"""
    SurrealValue(kind::SurrealValueKind, value)

A tagged union representing any SurrealDB value type. Used internally for
precision type handling when mapping to/from C FFI types in embedded mode.

Most users never construct one directly — `query` / `select` / etc. handle
the conversions automatically.
"""
struct SurrealValue
    kind::SurrealValueKind
    value::Any
end

# --- Auth types ---

"""
    RootAuth(username, password)

Root-level authentication credentials.
"""
struct RootAuth
    username::String
    password::String
end

"""
    NamespaceAuth(namespace, database, username, password)

Namespace-level authentication credentials.
"""
struct NamespaceAuth
    namespace::String
    database::String
    username::String
    password::String
end

"""
    ScopedAuth(namespace, database, access, username, password)

Scoped authentication credentials (record-level auth via an access method).
"""
struct ScopedAuth
    namespace::String
    database::String
    access::String
    username::String
    password::String
end

"""
    JwtAuth(token)

JWT token-based authentication. Use with `authenticate!`.
"""
struct JwtAuth
    token::String
end

# Password-redacting show methods. The default field-dump would print
# `RootAuth("root", "supersecret")` — anywhere a client logs an auth struct
# (debug printing, error messages, tracebacks) the password would leak.
# Tokens get truncated rather than fully redacted so debugging session
# misroute is still possible (first 8 chars of a JWT identify the
# algorithm/header, not the secret).
const _REDACTED = "***"
_truncate_token(t::AbstractString) = length(t) <= 12 ? _REDACTED :
    string(t[1:8], "…(", length(t), ")")

Base.show(io::IO, a::RootAuth) = print(io, "RootAuth(", a.username, ", ", _REDACTED, ")")
Base.show(io::IO, a::NamespaceAuth) =
    print(io, "NamespaceAuth(", a.namespace, "/", a.database, ", ",
              a.username, ", ", _REDACTED, ")")
Base.show(io::IO, a::ScopedAuth) =
    print(io, "ScopedAuth(", a.namespace, "/", a.database, "/", a.access,
              ", ", a.username, ", ", _REDACTED, ")")
Base.show(io::IO, a::JwtAuth) = print(io, "JwtAuth(", _truncate_token(a.token), ")")

# Convert auth structs to the parameter dict format expected by the RPC protocol
function _to_params(auth::RootAuth)
    return Dict("user" => auth.username, "pass" => auth.password)
end

function _to_params(auth::NamespaceAuth)
    return Dict("NS" => auth.namespace, "DB" => auth.database,
                "user" => auth.username, "pass" => auth.password)
end

function _to_params(auth::ScopedAuth)
    return Dict("NS" => auth.namespace, "DB" => auth.database,
                "AC" => auth.access,
                "user" => auth.username, "pass" => auth.password)
end

# --- Relationship ---

"""
    Relationship(in, relation, out; data=Dict())

Represents a graph relationship between two records.

# Examples
```julia
rel = Relationship("person:john", Table("knows"), "person:jane",
                    data=Dict("met" => "2024-01-01"))
```
"""
struct Relationship
    rel_in::Union{RecordID, String}
    relation::Table
    rel_out::Union{RecordID, String}
    data::Dict{String, Any}
end

# --- LiveSubscription ---

"""
    LiveSubscription(query_id, channel, client)

A live query subscription. Iterate over `sub.channel` to receive notifications.
Call `kill!(sub)` to terminate.

Fields:
- `query_id::String`: UUID string identifying the live query on the server
- `channel::Channel`: Julia Channel receiving notification dicts
- `active::Bool`: Whether the subscription is still active
"""
mutable struct LiveSubscription
    query_id::String
    channel::Channel
    client::Any                                    # SurrealClient (avoid circular dep)
    active::Bool
end

function Base.show(io::IO, sub::LiveSubscription)
    state = sub.active ? "active" : "killed"
    print(io, "LiveSubscription(", sub.query_id, ", ", state, ")")
end

# Iterate the underlying notification channel directly so callers can write
# `for n in sub` instead of `for n in sub.channel`. Matches Channel's own
# iteration semantics: blocks waiting for the next message; ends when the
# channel closes (via `kill!`).
Base.IteratorSize(::Type{LiveSubscription}) = Base.SizeUnknown()
Base.eltype(::Type{LiveSubscription}) = Any
Base.iterate(sub::LiveSubscription, state...) = iterate(sub.channel, state...)
