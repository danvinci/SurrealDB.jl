# L3 — TAG_STRING_DECIMAL (10): SurrealDB arbitrary-precision decimal.
#
# Wire shape: `Tag(10, text)` — server uses `rust_decimal` internally,
# emits / accepts the canonical string form. Ref: convert.rs:116-122
# (decode), 375-377 (encode).
#
# Julia mapping: a thin `String` wrapper, `SurrealDecimal`. Preserves
# wire precision exactly. No arithmetic; users who want it explicitly
# convert via `BigFloat(::SurrealDecimal)`.
#
# Why not `Decimals.jl` / `BigFloat` directly?
#   - `Decimals.jl` adds a non-stdlib transitive dep.
#   - `BigFloat` is binary-radix; round-tripping decimal strings is
#     lossy for many real values (e.g. 0.1 + 0.2 ≠ 0.3 territory).
#   - String wrapper round-trips bit-exact what the server emitted.

"""
    SurrealDecimal(s::AbstractString)

Wire-format wrapper for SurrealDB's Decimal. Stores the canonical
string form as emitted by the server. Construct from a literal string;
convert to `BigFloat` if arithmetic is needed (note: binary-radix
conversion is approximate).

```julia
SurrealDecimal("3.14159")
SurrealDecimal("-0.5")
BigFloat(SurrealDecimal("1.5"))   # 1.5 — exact in this case
```
"""
struct SurrealDecimal
    value::String
end

Base.string(d::SurrealDecimal) = d.value
Base.show(io::IO, d::SurrealDecimal) = print(io, "SurrealDecimal(\"", d.value, "\")")
Base.:(==)(a::SurrealDecimal, b::SurrealDecimal) = a.value == b.value
Base.hash(d::SurrealDecimal, h::UInt) = hash(d.value, hash(:SurrealDecimal, h))

Base.BigFloat(d::SurrealDecimal) = parse(BigFloat, d.value)

# --- CBOR encode / decode ---

function encode(io::IO, d::SurrealDecimal)
    n = write_head(io, MAJOR_TAG, TAG_STRING_DECIMAL)
    return n + encode(io, d.value)
end

function _decode_decimal(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_STRING_DECIMAL (10) payload must be text; got $(typeof(payload))"))
    return SurrealDecimal(String(payload))
end

_register_tag!(TAG_STRING_DECIMAL, _decode_decimal)
