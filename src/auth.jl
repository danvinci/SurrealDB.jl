# Authentication layer for SurrealDB.jl

# --- Sign in ---

"""
    signin!(client, auth)

Authenticate with the SurrealDB server.

`auth` can be:
- [`RootAuth`](@ref) — root-level credentials
- [`NamespaceAuth`](@ref) — namespace-level credentials
- [`ScopedAuth`](@ref) — record-level credentials via an access method
- `Dict{String, Any}` — raw parameters (e.g., for bearer keys, refresh tokens)

Returns the JWT token string on success.

# Examples
```julia
# Root auth
token = SurrealDB.signin!(db, SurrealDB.RootAuth("root", "password"))

# Namespace-level
token = SurrealDB.signin!(db, SurrealDB.NamespaceAuth("ns", "db", "user", "pass"))

# Scoped
token = SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "access", "user", "pass"))

# Raw params (bearer key, refresh tokens, etc.)
token = SurrealDB.signin!(db, Dict("NS" => "ns", "DB" => "db", "AC" => "access",
                                    "user" => "u", "pass" => "p"))
```
"""
# Single core impl; typed overloads convert to params via `_to_params`.
function _signin_impl!(client::SurrealClient, params)
    result = _rpc_call(client, "signin", Any[params])
    token = _extract_token(result)
    client.token = token
    return token
end

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
    client.token = token
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
    client.token = token
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
    client.token = nothing
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
