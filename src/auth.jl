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
