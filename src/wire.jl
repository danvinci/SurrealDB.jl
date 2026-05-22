# Wire-format codec dispatch — single seam between transport layers and the
# JSON / CBOR encoders. Transport code (`transport_ws.jl`, `transport_http.jl`)
# calls `_wire_encode` / `_wire_decode` and stays codec-agnostic. Dispatch is
# on the `W` type parameter of `RemoteConnection{P, W}`, so the path is
# resolved at compile time — no `if conn.wire == :cbor` runtime branches.
#
# JSON path returns/accepts `String` payloads; CBOR path returns/accepts
# `Vector{UInt8}`. Both `HTTP.WebSockets.send` and `HTTP.post` infer the
# WebSocket frame type / HTTP body type from this Julia type, so callers just
# pass the payload through unchanged.

# --- Wire-typed channel factory ---
#
# WS writer drains a `Channel` whose element type matches the wire payload:
# `Channel{String}` for JSON, `Channel{Vector{UInt8}}` for CBOR. Concrete
# element types let `HTTP.WebSockets.send` pick TEXT vs BINARY frames
# without runtime branching.
_new_write_channel(::Val{:json}) = Channel{String}(32)
_new_write_channel(::Val{:cbor}) = Channel{Vector{UInt8}}(32)

# Connection-typed convenience: lift the wire param so callers say
# `_new_write_channel(conn)` instead of `_new_write_channel(Val(_wire(conn)))`.
_new_write_channel(::RemoteConnection{P, W}) where {P, W} = _new_write_channel(Val(W))

# Wire-format introspection: pull `W` back out of a typed connection.
_wire(::RemoteConnection{P, W}) where {P, W} = W

# --- Encode ---

"""
    _wire_encode(conn, msg) -> Union{String, Vector{UInt8}}

Encode a Julia RPC envelope (`Dict{String, Any}`) for transmission. JSON
returns a UTF-8 `String`; CBOR returns canonical bytes via `SurrealCBOR.encode`.
"""
_wire_encode(::RemoteConnection{P, :json}, msg) where {P} = JSON.json(msg)

function _wire_encode(::RemoteConnection{P, :cbor}, msg) where {P}
    try
        return SurrealCBOR.encode(msg)
    catch e
        e isa SurrealCBOR.CBORError || rethrow()
        throw(SerializationError("CBOR encode failed: $(e.msg)"))
    end
end

# --- Decode ---

"""
    _wire_decode(conn, raw) -> Any

Decode a wire payload into a Julia value (typically `Dict{String, Any}` for
RPC envelopes). JSON path accepts `String` or `Vector{UInt8}` (UTF-8); CBOR
accepts `Vector{UInt8}` (or `String`, coerced via `codeunits`).
"""
function _wire_decode(::RemoteConnection{P, :json}, raw) where {P}
    s = raw isa String ? raw : String(raw)
    return JSON.parse(s)
end

function _wire_decode(::RemoteConnection{P, :cbor}, raw) where {P}
    bytes = raw isa AbstractVector{UInt8} ? raw : Vector{UInt8}(codeunits(raw))
    try
        return SurrealCBOR.decode(bytes)
    catch e
        e isa SurrealCBOR.CBORError || rethrow()
        throw(SerializationError("CBOR decode failed: $(e.msg)"; is_deserialization=true))
    end
end

# --- Wire-format introspection ---

"""
    _wire_subprotocol(conn) -> String

WebSocket `Sec-WebSocket-Protocol` value for this wire format. Sent in the
upgrade request; server echoes back the selected subprotocol.
"""
_wire_subprotocol(::RemoteConnection{P, :json}) where {P} = "json"
_wire_subprotocol(::RemoteConnection{P, :cbor}) where {P} = "cbor"

"""
    _wire_content_type(conn) -> String

HTTP `Content-Type` / `Accept` value for this wire format.
"""
_wire_content_type(::RemoteConnection{P, :json}) where {P} = "application/json"
_wire_content_type(::RemoteConnection{P, :cbor}) where {P} = "application/cbor"
