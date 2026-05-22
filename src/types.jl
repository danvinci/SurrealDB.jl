# Core data types for SurrealDB.jl

# Wire-format Surreal types (RecordID, Table, ...) live under
# `cbor/types/` per design-cbor-transport.md — substrate-isolated codec
# layer designed for clean extraction. Re-exported at the SurrealDB
# level via `using .SurrealCBOR` in SurrealDB.jl so user-facing names
# resolve unchanged.
#
# What stays in this file: auth types, SurrealValue (FFI marshaling),
# Relationship, LiveSubscription, LiveNotification, ConnectionStatus —
# none of those cross the CBOR wire as tagged values.

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
    ScopedAuth(namespace, database, access, params::AbstractDict)

Scoped authentication credentials (record-level auth via an access method).

The 5-arg form is the convenience case for SIGNIN clauses that reference
`\$user` / `\$pass`. The dict form passes through arbitrary keys for SIGNIN
clauses referencing other params (`\$email`, `\$name`, etc.).

```julia
SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "user_access", "alice", "hunter2"))
SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "user_access",
                                            Dict("email" => "a@example.com",
                                                 "pass"  => "hunter2")))
```
"""
struct ScopedAuth
    namespace::String
    database::String
    access::String
    username::String
    password::String
    extra::Dict{String, Any}
end

ScopedAuth(ns::AbstractString, db::AbstractString, ac::AbstractString,
           user::AbstractString, pass::AbstractString) =
    ScopedAuth(String(ns), String(db), String(ac), String(user), String(pass),
               Dict{String, Any}())

function ScopedAuth(ns::AbstractString, db::AbstractString, ac::AbstractString,
                    params::AbstractDict)
    user = string(get(params, "user", ""))
    pass = string(get(params, "pass", ""))
    extra = Dict{String, Any}(string(k) => v for (k, v) in params if string(k) ∉ ("user", "pass"))
    return ScopedAuth(String(ns), String(db), String(ac), user, pass, extra)
end

"""
    JwtAuth(token)

JWT token-based authentication. Use with `authenticate!`.
"""
struct JwtAuth
    token::String
end

"""
    Tokens(access::String, refresh::Union{String, Nothing})

Typed pair of tokens returned by SurrealDB sign-in flows that opted into
`WITH REFRESH` on the access method. `access` is the short-lived JWT used
for authenticated RPCs; `refresh` is the longer-lived token exchanged via
the `refresh` RPC for a new access token. `refresh` is `nothing` when the
auth mode doesn't issue one (Root/Namespace/legacy Scope).
"""
struct Tokens
    access::String
    refresh::Union{String, Nothing}
end

Tokens(access::AbstractString) = Tokens(String(access), nothing)

function Base.show(io::IO, t::Tokens)
    rf = isnothing(t.refresh) ? "-" : _truncate_token(t.refresh)
    print(io, "Tokens(access=", _truncate_token(t.access), ", refresh=", rf, ")")
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
function Base.show(io::IO, a::ScopedAuth)
    print(io, "ScopedAuth(", a.namespace, "/", a.database, "/", a.access,
              ", ", a.username, ", ", _REDACTED)
    if !isempty(a.extra)
        # Redact full extra block: callers may stash secrets there (api keys,
        # one-time codes). Print only key names.
        print(io, ", extra=[", join(sort!(collect(keys(a.extra))), ","), "]=", _REDACTED)
    end
    print(io, ")")
end
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
    p = Dict{String, Any}("NS" => auth.namespace, "DB" => auth.database,
                          "AC" => auth.access,
                          "user" => auth.username, "pass" => auth.password)
    for (k, v) in auth.extra
        p[k] = v
    end
    return p
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

# --- LiveNotification ---

"""
    LiveNotification(action, query_id, record, result, session)

One live-query event delivered to a [`LiveSubscription`](@ref) channel.
Subtype of `AbstractDict{String, Any}` so legacy `n["action"]` access keeps
working alongside the typed `n.action` form.

Fields:
- `action::String`: `"CREATE"`, `"UPDATE"`, or `"DELETE"` (`"KILLED"` events are dropped by the dispatcher)
- `query_id::String`: live UUID matching `sub.query_id`
- `record::Union{String, Nothing}`: affected record id, e.g. `"users:abc"`
- `result::Any`: payload — the record on CREATE/UPDATE, the pre-delete record on DELETE
- `session::Union{String, Nothing}`: v3 session id; `nothing` on v2
"""
struct LiveNotification <: AbstractDict{String, Any}
    action::String
    query_id::String
    record::Union{String, Nothing}
    result::Any
    session::Union{String, Nothing}
end

function LiveNotification(d::AbstractDict)
    LiveNotification(
        string(get(d, "action", "")),
        string(get(d, "id", "")),
        _opt_string(get(d, "record", nothing)),
        get(d, "result", nothing),
        _opt_string(get(d, "session", nothing)),
    )
end

_opt_string(x) = isnothing(x) ? nothing : string(x)

# AbstractDict interface — backwards-compat dict access.
const _LIVE_NOTIF_KEYS = ("action", "id", "record", "result", "session")
Base.length(::LiveNotification) = 5
Base.keys(::LiveNotification) = _LIVE_NOTIF_KEYS
function Base.haskey(::LiveNotification, k)
    s = k isa AbstractString ? String(k) : string(k)
    return s in _LIVE_NOTIF_KEYS
end
function Base.getindex(n::LiveNotification, k)
    s = k isa AbstractString ? String(k) : string(k)
    s == "action"  && return n.action
    s == "id"      && return n.query_id
    s == "record"  && return n.record
    s == "result"  && return n.result
    s == "session" && return n.session
    throw(KeyError(k))
end
function Base.get(n::LiveNotification, k, default)
    s = k isa AbstractString ? String(k) : string(k)
    s == "action"  && return n.action
    s == "id"      && return n.query_id
    s == "record"  && return n.record
    s == "result"  && return n.result
    s == "session" && return n.session
    return default
end
function Base.iterate(n::LiveNotification, state=1)
    state > 5 && return nothing
    p = state == 1 ? ("action"  => n.action)    :
        state == 2 ? ("id"      => n.query_id)  :
        state == 3 ? ("record"  => n.record)    :
        state == 4 ? ("result"  => n.result)    :
                     ("session" => n.session)
    return p, state + 1
end

function Base.show(io::IO, n::LiveNotification)
    rec = isnothing(n.record) ? "-" : n.record
    print(io, "LiveNotification(", n.action, " ", rec, ")")
end

# --- LiveSubscription ---

"""
    LiveSubscription(query_id, channel, client)

A live query subscription. Iterate over `sub.channel` (or `sub` directly) to
receive [`LiveNotification`](@ref) events. Call `kill!(sub)` to terminate.

Fields:
- `query_id::String`: UUID string identifying the live query on the server
- `channel::Channel`: receives `LiveNotification` events
- `active::Bool`: subscription state
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
