# L3 — DateTime handlers.
#
# Two tags:
#   TAG_CUSTOM_DATETIME (12) — `[i64 seconds, u32 nanos]`. Server emits.
#                              Ref: convert.rs:76-101, 395-405.
#   TAG_SPEC_DATETIME   (0)  — RFC 3339 text. Decode-only.
#                              Ref: convert.rs:68-74.
#
# Why a custom `SurrealDateTime` rather than `Dates.DateTime`?
#   Julia stdlib `DateTime` is millisecond precision; the wire carries
#   nanoseconds. Round-tripping via stdlib would silently lose the
#   sub-ms component. `SurrealDateTime(seconds, nanos)` preserves the
#   full wire fidelity; conversion to `Dates.DateTime` is explicit and
#   documented as lossy.

"""
    SurrealDateTime(seconds::Int64, nanos::UInt32)

Wire-format datetime: seconds since the Unix epoch (1970-01-01 UTC) +
sub-second nanoseconds (`0..999_999_999`). UTC; no timezone offset is
stored (wire form always normalizes to UTC).

```julia
SurrealDateTime(1_716_423_296, UInt32(123_456_789))  # 2024-05-22T...
```

Convert to / from `Dates.DateTime`:

```julia
Dates.DateTime(SurrealDateTime(1_716_423_296, UInt32(123_000_000)))
# 2024-05-22T22:54:56.123 — sub-ms portion rounded
SurrealDateTime(Dates.DateTime(2024, 5, 22))
# SurrealDateTime(1716336000, 0x00000000)
```
"""
struct SurrealDateTime
    seconds::Int64
    nanos::UInt32
    function SurrealDateTime(seconds::Integer, nanos::Integer)
        0 <= nanos < 1_000_000_000 || throw(ArgumentError(
            "nanos must be in [0, 1_000_000_000), got $nanos"))
        new(Int64(seconds), UInt32(nanos))
    end
end

Base.:(==)(a::SurrealDateTime, b::SurrealDateTime) =
    a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(d::SurrealDateTime, h::UInt) =
    hash(d.nanos, hash(d.seconds, hash(:SurrealDateTime, h)))

function Base.show(io::IO, d::SurrealDateTime)
    print(io, "SurrealDateTime(", d.seconds, ", 0x",
          string(d.nanos; base=16, pad=8), ")")
end

# Conversion helpers. Stdlib DateTime is ms precision — sub-ms rounds.
const _UNIX_EPOCH = Dates.DateTime(1970, 1, 1)

function Base.convert(::Type{Dates.DateTime}, d::SurrealDateTime)
    ms_extra = round(Int, d.nanos / 1_000_000)
    return _UNIX_EPOCH + Dates.Second(d.seconds) + Dates.Millisecond(ms_extra)
end
Dates.DateTime(d::SurrealDateTime) = convert(Dates.DateTime, d)

function SurrealDateTime(dt::Dates.DateTime)
    ms_since_epoch = Dates.value(dt - _UNIX_EPOCH)
    seconds = fld(ms_since_epoch, 1000)
    nanos = UInt32(mod(ms_since_epoch, 1000) * 1_000_000)
    return SurrealDateTime(seconds, nanos)
end

# --- CBOR encode / decode ---

# Encode: emit server-canonical Tag(12, [i64 seconds, u32 nanos]).
function encode(io::IO, d::SurrealDateTime)
    n = write_head(io, MAJOR_TAG, TAG_CUSTOM_DATETIME)
    return n + encode(io, Any[d.seconds, UInt64(d.nanos)])
end

# Tag 12 decoder: [seconds, nanos] array.
function _decode_datetime_array(payload)
    payload isa AbstractVector && length(payload) == 2 || throw(CBORError(
        "TAG_CUSTOM_DATETIME (12) payload must be 2-element array; got $(typeof(payload))"))
    seconds = payload[1]
    nanos = payload[2]
    seconds isa Integer || throw(CBORError(
        "TAG_CUSTOM_DATETIME (12): seconds must be integer, got $(typeof(seconds))"))
    nanos isa Integer || throw(CBORError(
        "TAG_CUSTOM_DATETIME (12): nanos must be integer, got $(typeof(nanos))"))
    return SurrealDateTime(seconds, nanos)
end

# Tag 0 decoder (decode-only): RFC 3339 text. Manual parse to preserve
# nanosecond precision past Dates.DateTime's millisecond ceiling.
const _ISO_DATETIME_RE = r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})$"

function _decode_datetime_string(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_SPEC_DATETIME (0) payload must be text; got $(typeof(payload))"))
    m = match(_ISO_DATETIME_RE, payload)
    isnothing(m) && throw(CBORError(
        "TAG_SPEC_DATETIME (0): unrecognized RFC 3339 datetime `$payload`"))

    year, month, day = parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
    hour, minute, sec = parse(Int, m.captures[4]), parse(Int, m.captures[5]), parse(Int, m.captures[6])

    base = Dates.DateTime(year, month, day, hour, minute, sec)
    seconds = Int64(Dates.value(base - _UNIX_EPOCH) ÷ 1000)

    # Timezone offset → subtract to reach UTC.
    tz = m.captures[8]
    if tz != "Z"
        sign = tz[1] == '+' ? -1 : 1
        tz_no_colon = replace(tz[2:end], ":" => "")
        h_off = parse(Int, tz_no_colon[1:2])
        m_off = parse(Int, tz_no_colon[3:4])
        seconds += sign * (h_off * 3600 + m_off * 60)
    end

    # Fractional seconds → nanos. Pad / truncate to 9 digits.
    nanos = UInt32(0)
    if !isnothing(m.captures[7])
        frac = m.captures[7]
        frac = length(frac) >= 9 ? frac[1:9] : rpad(frac, 9, '0')
        nanos = parse(UInt32, frac)
    end

    return SurrealDateTime(seconds, nanos)
end

_register_tag!(TAG_CUSTOM_DATETIME, _decode_datetime_array)
_register_tag!(TAG_SPEC_DATETIME,   _decode_datetime_string)
