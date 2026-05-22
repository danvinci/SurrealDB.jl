# Authentication layer for SurrealDB.jl

# --- Sign in ---

# Single core impl; typed overloads convert to params via `_to_params`.
function _signin_impl!(client::SurrealClient, params)
    result = _rpc_call(client, "signin", Any[params])
    token = _extract_token(result)
    refresh = _extract_refresh(result)
    _apply_tokens!(client, token, refresh)
    return token
end

"""
    signin!(client, auth) -> token::String

Authenticate with the SurrealDB server.

`auth` can be:
- [`RootAuth`](@ref) - root-level credentials
- [`NamespaceAuth`](@ref) - namespace-level credentials
- [`ScopedAuth`](@ref) - record-level credentials via an access method
- `Dict{String, Any}` - raw parameters (e.g., for bearer keys, refresh tokens)

Returns the JWT token string on success. The SDK stores the token on the
client so subsequent RPCs are authenticated automatically; the token is
also replayed on reconnect.

# Examples
```julia
token = SurrealDB.signin!(db, SurrealDB.RootAuth("root", "password"))

token = SurrealDB.signin!(db, SurrealDB.NamespaceAuth("ns", "db", "user", "pass"))

token = SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "access", "user", "pass"))

token = SurrealDB.signin!(db, Dict("NS" => "ns", "DB" => "db", "AC" => "access",
                                    "user" => "u", "pass" => "p"))
```
"""
function signin!(client::SurrealClient{C}, auth::RootAuth) where {C<:AbstractConnection}
    return _signin_impl!(client, _to_params(auth))
end

function signin!(client::SurrealClient{C}, auth::NamespaceAuth) where {C<:AbstractConnection}
    return _signin_impl!(client, _to_params(auth))
end

function signin!(client::SurrealClient{C}, auth::ScopedAuth) where {C<:AbstractConnection}
    return _signin_impl!(client, _to_params(auth))
end

# Raw-Dict overload — caller provides params as-is (e.g. for bearer keys)
function signin!(client::SurrealClient{C}, params) where {C<:AbstractConnection}
    return _signin_impl!(client, params)
end

# --- Sign up ---

"""
    signup!(client, auth::ScopedAuth)

Register a new user via a RECORD-scope access method.

Returns the JWT token string on success.

Note: SurrealDB signup is only available with RECORD-scoped access methods.
"""
function signup!(client::SurrealClient{C}, auth::ScopedAuth) where {C<:AbstractConnection}
    params = _to_params(auth)
    result = _rpc_call(client, "signup", Any[params])
    token = _extract_token(result)
    refresh = _extract_refresh(result)
    _apply_tokens!(client, token, refresh)
    return token
end

# --- Authenticate with JWT ---

"""
    authenticate!(client, token::String)

Authenticate the current connection with a pre-obtained JWT token.

This is useful when you have a JWT from a previous signin or an external auth system.

# Examples
```julia
SurrealDB.authenticate!(db, "eyJ0eXAiOiJKV1QiLCJh...")
```
"""
function authenticate!(client::SurrealClient{C}, token::String) where {C<:AbstractConnection}
    _rpc_call(client, "authenticate", Any[token])
    # External token: no refresh component. Carry over an existing refresh
    # token only if the caller is re-applying the same access token (e.g.
    # reconnect replay) — otherwise the prior refresh belongs to a different
    # session and must be dropped.
    existing = client.tokens
    refresh = (existing !== nothing && existing.access == token) ? existing.refresh : nothing
    _apply_tokens!(client, token, refresh)
    return nothing
end

# --- Invalidate ---

"""
    invalidate!(client)

Clear the current authentication session.
Subsequent operations will be unauthenticated.
"""
function invalidate!(client::SurrealClient{C}) where {C<:AbstractConnection}
    _rpc_call(client, "invalidate", Any[])
    _clear_tokens!(client)
    return nothing
end

# --- Internal helpers ---

function _extract_token(result)
    if result isa String
        return result
    elseif result isa Dict && haskey(result, "token")
        return result["token"]
    elseif result isa Dict && haskey(result, "access")
        return result["access"]
    else
        return string(result)
    end
end

# Pull a refresh token out of a signin/signup/refresh response. Returns
# `nothing` if the server didn't issue one (legacy scopes, Root/NS auth,
# scopes without `WITH REFRESH`).
function _extract_refresh(result)
    result isa AbstractDict || return nothing
    v = get(result, "refresh", nothing)
    v === nothing && return nothing
    return v isa AbstractString ? String(v) : string(v)
end

# Single owner for the (token, tokens, refresh-timer) tuple. Centralises the
# invariant that `client.token == client.tokens.access` whenever
# `client.tokens !== nothing`, and ensures any pre-existing refresh timer is
# replaced rather than leaked.
function _apply_tokens!(client::SurrealClient, access::AbstractString,
                        refresh::Union{AbstractString, Nothing})
    client.token = String(access)
    client.tokens = Tokens(access, refresh)
    _reschedule_refresh_timer!(client)
    return nothing
end

function _clear_tokens!(client::SurrealClient)
    client.token = nothing
    client.tokens = nothing
    _cancel_refresh_timer!(client)
    return nothing
end

# Refresh-timer hooks. Overridden by remote-connection methods below; the
# default no-op makes embedded clients (no timer field) Just Work.
_reschedule_refresh_timer!(::SurrealClient) = nothing
_cancel_refresh_timer!(::SurrealClient) = nothing

# --- JWT exp parsing ---

# Base64-url decode tolerant of the missing `=` padding JWT segments use.
# Returns `nothing` on any decode failure so callers can degrade gracefully
# rather than throw on a malformed token.
function _b64url_decode(s::AbstractString)
    # Translate URL-safe alphabet to standard, then pad to multiple of 4.
    t = replace(String(s), '-' => '+', '_' => '/')
    pad = (4 - (length(t) % 4)) % 4
    t = t * repeat("=", pad)
    return try
        Base64.base64decode(t)
    catch
        nothing
    end
end

"""
    _parse_jwt_exp(token::String) -> Union{Int, Nothing}

Decode the `exp` (expiration) claim from a JWT's payload segment as a Unix
epoch timestamp in seconds. Returns `nothing` for any token that doesn't
parse cleanly or doesn't carry an `exp` claim — callers treat that as "no
proactive refresh scheduled" rather than an error condition (the server is
the source of truth for token validity).
"""
function _parse_jwt_exp(token::AbstractString)::Union{Int, Nothing}
    parts = split(String(token), '.')
    length(parts) >= 2 || return nothing
    payload_bytes = _b64url_decode(parts[2])
    payload_bytes === nothing && return nothing
    payload = try
        JSON.parse(String(payload_bytes))
    catch
        return nothing
    end
    payload isa AbstractDict || return nothing
    exp = get(payload, "exp", nothing)
    exp === nothing && return nothing
    return exp isa Integer ? Int(exp) :
           exp isa Real ? Int(floor(exp)) :
           nothing
end

# --- refresh! ---

"""
    refresh!(client) -> token::String

Exchange the current refresh token for a new access + refresh pair via the
SurrealDB `refresh` RPC. Updates `client.tokens` and `client.token` on
success and reschedules the proactive refresh timer against the new `exp`
claim. Returns the new access token.

Throws [`NotAllowedError`](@ref) if the client has no refresh token to
spend (Root/NS auth, scopes without `WITH REFRESH`, or after `invalidate!`).
"""
function refresh!(client::SurrealClient{C}) where {C<:AbstractConnection}
    tks = client.tokens
    if tks === nothing || tks.refresh === nothing
        throw(NotAllowedError("No refresh token available; sign in with `WITH REFRESH` scope first."))
    end
    result = _rpc_call(client, "refresh", Any[tks.refresh])
    new_access = _extract_token(result)
    # Server may rotate the refresh token or keep the old one — fall back to
    # the existing refresh when the response omits a fresh one.
    new_refresh = _extract_refresh(result)
    if new_refresh === nothing
        new_refresh = tks.refresh
    end
    _apply_tokens!(client, new_access, new_refresh)
    return new_access
end

# --- Proactive refresh timer ---

# Remote-client overrides for the no-op hooks declared above. Embedded
# clients keep the no-op behavior — there's no exp to act on.
function _reschedule_refresh_timer!(client::SurrealClient{<:RemoteConnection})
    _schedule_refresh_timer!(client.connection, client)
    return nothing
end

function _cancel_refresh_timer!(client::SurrealClient{<:RemoteConnection})
    _stop_refresh_timer!(client.connection)
    return nothing
end

# Schedule a one-shot Timer that fires `refresh_lead_time` seconds before
# the access token's `exp` claim. Skips scheduling when:
#   - the client has no tokens (cleared via `invalidate!`/`close!`)
#   - the access token has no parseable `exp` claim
#   - no refresh token is available to spend
# Already-expired (or near-expired) tokens fire the callback immediately by
# scheduling a 0-second timer; the callback handles failure by clearing
# tokens and emitting a @warn — the connection stays up.
function _schedule_refresh_timer!(conn::RemoteConnection, client::SurrealClient)
    _stop_refresh_timer!(conn)
    tks = client.tokens
    (tks === nothing || tks.refresh === nothing) && return nothing
    exp = _parse_jwt_exp(tks.access)
    exp === nothing && return nothing
    now_s = time()
    delay = max(0.0, Float64(exp) - now_s - conn.refresh_lead_time)
    conn.refresh_timer = Timer(delay) do _
        try
            refresh!(client)
        catch e
            @warn "SurrealDB proactive refresh failed; clearing tokens" exception=e
            _clear_tokens!(client)
        end
    end
    return nothing
end

function _stop_refresh_timer!(conn::RemoteConnection)
    t = conn.refresh_timer
    if t !== nothing
        try; close(t); catch; end
    end
    conn.refresh_timer = nothing
    return nothing
end
