# Record IDs

A record id targets a specific row in a table.
Three forms are supported, picked by intent:

```julia
RecordID("user", "42")        # programmatic
rid"user:42"                  # compile-time literal
StringRecordID("user:42")     # server-side parse (escape hatch)
```

## RecordID

[`RecordID`](@ref) is the canonical typed form.
Use it when the table or id is computed at runtime:

```julia
RecordID("user", "42")
RecordID("user", 42)            # integer id
RecordID("user", uuid4())       # UUID id
RecordID("event", [2024, 1])    # composite (array) id
```

The CBOR wire shape is `Tag(8, [table, key])`.
On decode, a record id always materializes as `RecordID` regardless of how it was sent.

## `rid"..."` macro

For literals in source code, the [`@rid_str`](@ref) macro parses at compile time:

```julia
rid"user:42"                  # ≡ RecordID("user", "42")
rid"posts:abc-with-dashes"    # ≡ RecordID("posts", "abc-with-dashes")
```

Validation runs at parse time: exactly one `:` separator, both sides non-empty.
Multi-colon strings and empty parts raise `ArgumentError` before the program runs.
For complex ids that need server-side parsing, use `StringRecordID` instead.

## StringRecordID

[`StringRecordID`](@ref) is an opaque wrapper for cases where the id syntax needs the server's SurrealQL parser:

```julia
StringRecordID("posts:[2024-01-15, 'ulid']")
StringRecordID("users:⟨email@example.com⟩")
```

The wire shape is `Tag(8, text)` — same `TAG_RECORDID` as the typed form, but with a text payload.
The server runs its full parser on the string.
Send-only: decoded values are always typed `RecordID`, never `StringRecordID`.

## Plain strings

A plain `String` argument to a record-op method is treated as a **table name** (auto-id):

```julia
SurrealDB.create(db, "user", Dict("name" => "Alice"))   # creates user with auto-id
```

A plain `String` containing `:` raises `ArgumentError` and points at the three typed forms:

```julia
SurrealDB.create(db, "user:42", data)
# ArgumentError: ambiguous record-id form "user:42": plain `String`
# containing ':' is not auto-parsed. Use one of:
#   RecordID(table, id)
#   rid"table:id"
#   StringRecordID("user:42")
```

This avoids the silent footgun where `"user:42"` could be reinterpreted as a table name `user:42` with an auto-generated id.
