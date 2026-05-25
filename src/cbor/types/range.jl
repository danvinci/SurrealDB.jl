# L3 — Range + Bound markers (tags 49, 50, 51).
#
# Wire shapes:
#   TAG_RANGE          (49) — `[start_bound, end_bound]`
#   TAG_BOUND_INCLUDED (50) — nested value
#   TAG_BOUND_EXCLUDED (51) — nested value
#
# Each bound on the wire is one of: `Tag(50, v)` / `Tag(51, v)` / `Null`
# (unbounded). Bound payloads can themselves be ranges (range-of-range
# legal). Refs: convert.rs:193, 511-542 (range), 514-518 (bound markers).

function encode(io::IO, b::BoundIncluded)
    n = write_head(io, MAJOR_TAG, TAG_BOUND_INCLUDED)
    return n + encode(io, b.value)
end

function encode(io::IO, b::BoundExcluded)
    n = write_head(io, MAJOR_TAG, TAG_BOUND_EXCLUDED)
    return n + encode(io, b.value)
end

function encode(io::IO, r::SurrealRange)
    n = write_head(io, MAJOR_TAG, TAG_RANGE)
    return n + encode(io, Any[r.start, r.stop])
end

# Decoders. Bound markers wrap whatever inner value the L2 already
# decoded. The Range decoder validates the [start, stop] array shape.

_decode_bound_included(payload) = BoundIncluded(payload)
_decode_bound_excluded(payload) = BoundExcluded(payload)

function _decode_range(payload)
    payload isa AbstractVector && length(payload) == 2 || throw(CBORError(
        "TAG_RANGE (49) payload must be 2-element array; got $(typeof(payload))"))
    start_bound = payload[1]
    stop_bound = payload[2]
    _check_bound_decoded(start_bound, "start")
    _check_bound_decoded(stop_bound, "stop")
    return SurrealRange(start_bound, stop_bound)
end

function _check_bound_decoded(b, name)
    isnothing(b) || b isa BoundIncluded || b isa BoundExcluded || throw(CBORError(
        "TAG_RANGE (49) $name bound must be Tag(50), Tag(51), or null; got $(typeof(b))"))
end

_register_tag!(TAG_BOUND_INCLUDED, _decode_bound_included)
_register_tag!(TAG_BOUND_EXCLUDED, _decode_bound_excluded)
_register_tag!(TAG_RANGE,          _decode_range)
