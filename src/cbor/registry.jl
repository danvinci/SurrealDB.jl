# L3 — tag decoder registry.
#
# Each registered tag has a function `payload -> typed_value` that runs
# post-L2-decode on Tag(n) payloads. Unregistered tags fall through to
# the generic `Tagged(n, payload)` wrapper from L2.
#
# Registration is closed in production (hardcoded ~25 entries via
# include order in SurrealCBOR.jl). The registry isn't user-facing API;
# if the submodule is ever extracted as standalone, opening this up is
# the natural extension point.
#
# Decoder functions throw `CBORError` on malformed payloads (e.g., a
# Tag(6) with non-null payload).

const _TAG_DECODERS = Dict{UInt64, Function}()

"""
    _register_tag!(tag::UInt64, decoder)

Bind a payload-transforming decoder to `tag`. The decoder runs after
L2 has parsed the tag's nested value: it receives the decoded payload
and returns the typed Julia value (or throws `CBORError`).

Called from `types/*.jl` at module-load time. Idempotent re-registration
(same tag, same decoder) is a no-op; conflicting re-registration errors.
"""
function _register_tag!(tag::UInt64, decoder::Function)
    existing = get(_TAG_DECODERS, tag, nothing)
    if isnothing(existing)
        _TAG_DECODERS[tag] = decoder
    elseif existing !== decoder
        throw(ArgumentError("CBOR tag $tag already has a different decoder registered"))
    end
    return nothing
end

"""
    _lookup_tag(tag::UInt64) -> Union{Function, Nothing}

Return the registered decoder for `tag`, or `nothing` if unregistered.
"""
_lookup_tag(tag::UInt64) = get(_TAG_DECODERS, tag, nothing)
