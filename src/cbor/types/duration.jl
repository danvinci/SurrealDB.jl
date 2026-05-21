# L3 — Duration handlers.
#
# Two tags:
#   TAG_CUSTOM_DURATION (14) — variable-length array: `[]`, `[secs]`, or
#                              `[secs, nanos]`. Server emits compact form.
#                              Ref: convert.rs:132-155, 380-393.
#   TAG_STRING_DURATION (13) — SurrealQL duration text (e.g. `"1h30m"`).
#                              Decode-only. Ref: convert.rs:124-130.
#
# Julia type: `SurrealDuration(seconds::UInt64, nanos::UInt32)`. Stdlib
# `Dates.Period` lacks nanosecond resolution natively, so we own the
# wire-fidelity type as with `SurrealDateTime`.

"""
    SurrealDuration(seconds::Integer, nanos::Integer)

Wire-format duration: non-negative seconds + sub-second nanoseconds
(`0..999_999_999`). Server-canonical encode emits the shortest form:

- `(0, 0)`        → empty array
- `(s, 0)`        → `[s]`
- `(s, ns)`       → `[s, ns]`

```julia
SurrealDuration(0, 0)              # zero
SurrealDuration(3600, 0)           # 1h
SurrealDuration(0, 500_000_000)    # 0.5s
SurrealDuration(3600, 500_000_000) # 1h 0.5s
```
"""
struct SurrealDuration
    seconds::UInt64
    nanos::UInt32
    function SurrealDuration(seconds::Integer, nanos::Integer)
        seconds >= 0 || throw(ArgumentError(
            "seconds must be non-negative, got $seconds"))
        0 <= nanos < 1_000_000_000 || throw(ArgumentError(
            "nanos must be in [0, 1_000_000_000), got $nanos"))
        new(UInt64(seconds), UInt32(nanos))
    end
end

Base.:(==)(a::SurrealDuration, b::SurrealDuration) =
    a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(d::SurrealDuration, h::UInt) =
    hash(d.nanos, hash(d.seconds, hash(:SurrealDuration, h)))

function Base.show(io::IO, d::SurrealDuration)
    print(io, "SurrealDuration(", d.seconds, ", ", d.nanos, ")")
end

# --- CBOR encode / decode ---

# Encode: server-canonical compact form (convert.rs:384-391).
function encode(io::IO, d::SurrealDuration)
    n = write_head(io, MAJOR_TAG, TAG_CUSTOM_DURATION)
    if d.seconds == 0 && d.nanos == 0
        return n + encode(io, UInt64[])
    elseif d.nanos == 0
        return n + encode(io, UInt64[d.seconds])
    else
        return n + encode(io, UInt64[d.seconds, UInt64(d.nanos)])
    end
end

# Tag 14 decoder: variable-length array.
function _decode_duration_array(payload)
    payload isa AbstractVector || throw(CBORError(
        "TAG_CUSTOM_DURATION (14) payload must be array; got $(typeof(payload))"))
    length(payload) <= 2 || throw(CBORError(
        "TAG_CUSTOM_DURATION (14) array must have <= 2 elements; got $(length(payload))"))
    secs = length(payload) >= 1 ? payload[1] : 0
    nanos = length(payload) >= 2 ? payload[2] : 0
    secs isa Integer || throw(CBORError(
        "TAG_CUSTOM_DURATION (14): seconds must be integer, got $(typeof(secs))"))
    nanos isa Integer || throw(CBORError(
        "TAG_CUSTOM_DURATION (14): nanos must be integer, got $(typeof(nanos))"))
    return SurrealDuration(secs, nanos)
end

# Tag 13 decoder (decode-only): SurrealQL duration text. Format is
# `<num><unit>[<num><unit>...]`. Units supported here: ns, us, µs, ms,
# s, m, h, d, w. Calendar-relative units (y) are intentionally not
# supported — ambiguous arithmetic. If peer SDKs emit those we surface
# an error rather than silently drift.
const _DURATION_UNITS = Dict{String, UInt128}(
    "ns" => UInt128(1),
    "us" => UInt128(1_000),
    "µs" => UInt128(1_000),
    "ms" => UInt128(1_000_000),
    "s"  => UInt128(1_000_000_000),
    "m"  => UInt128(60) * 1_000_000_000,
    "h"  => UInt128(3_600) * 1_000_000_000,
    "d"  => UInt128(86_400) * 1_000_000_000,
    "w"  => UInt128(7) * 86_400 * 1_000_000_000,
)
const _DURATION_RE = r"(\d+)(ns|us|µs|ms|s|m|h|d|w)"

function _decode_duration_string(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_STRING_DURATION (13) payload must be text; got $(typeof(payload))"))
    matches = collect(eachmatch(_DURATION_RE, payload))
    isempty(matches) && throw(CBORError(
        "TAG_STRING_DURATION (13): no duration components in `$payload`"))
    # Validate that the regex matches consumed the entire input. Compare
    # in byte-units (ncodeunits) not characters — "µs" is 2 UTF-8 bytes,
    # 1 codepoint.
    total_consumed = sum(m -> ncodeunits(m.match), matches)
    total_consumed == ncodeunits(payload) || throw(CBORError(
        "TAG_STRING_DURATION (13): unparseable suffix in `$payload`"))
    total_ns = UInt128(0)
    for m in matches
        n = parse(UInt128, m.captures[1])
        unit = m.captures[2]
        total_ns += n * _DURATION_UNITS[unit]
    end
    secs = total_ns ÷ UInt128(1_000_000_000)
    rem_ns = total_ns % UInt128(1_000_000_000)
    secs <= typemax(UInt64) || throw(CBORError(
        "TAG_STRING_DURATION (13): duration exceeds u64 seconds in `$payload`"))
    return SurrealDuration(UInt64(secs), UInt32(rem_ns))
end

_register_tag!(TAG_CUSTOM_DURATION, _decode_duration_array)
_register_tag!(TAG_STRING_DURATION, _decode_duration_string)
