# L3 — TAG_FILE (55): SurrealDB file reference.
#
# Wire shape: `Tag(55, [bucket_text, key_text])`. Ref convert.rs:337-352
# (decode), 437-443 (encode).

"""
    SurrealFile(bucket::AbstractString, key::AbstractString)

Reference to a file in a SurrealDB-managed bucket. Both `bucket` and
`key` are opaque strings; SDK doesn't validate path syntax.

```julia
SurrealFile("avatars", "user_42/profile.png")
```
"""
struct SurrealFile
    bucket::String
    key::String
    SurrealFile(bucket::AbstractString, key::AbstractString) =
        new(String(bucket), String(key))
end

Base.:(==)(a::SurrealFile, b::SurrealFile) = a.bucket == b.bucket && a.key == b.key
Base.hash(f::SurrealFile, h::UInt) =
    hash(f.key, hash(f.bucket, hash(:SurrealFile, h)))

function Base.show(io::IO, f::SurrealFile)
    print(io, "SurrealFile(\"", f.bucket, "\", \"", f.key, "\")")
end

# --- CBOR encode / decode ---

function encode(io::IO, f::SurrealFile)
    n = write_head(io, MAJOR_TAG, TAG_FILE)
    return n + encode(io, Any[f.bucket, f.key])
end

function _decode_file(payload)
    payload isa AbstractVector && length(payload) == 2 || throw(CBORError(
        "TAG_FILE (55) payload must be 2-element array; got $(typeof(payload))"))
    bucket = payload[1]
    key = payload[2]
    bucket isa AbstractString || throw(CBORError(
        "TAG_FILE (55): bucket must be string, got $(typeof(bucket))"))
    key isa AbstractString || throw(CBORError(
        "TAG_FILE (55): key must be string, got $(typeof(key))"))
    return SurrealFile(bucket, key)
end

_register_tag!(TAG_FILE, _decode_file)
