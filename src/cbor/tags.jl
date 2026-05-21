# L3 — SurrealDB CBOR tag constants.
#
# Cross-verified against the Rust server source:
#   ~/Documents/refs/surrealdb-rust/surrealdb/core/src/rpc/format/cbor/convert.rs:19-53
#
# Direction column (server perspective):
#   E  — emitted by server (and by us)
#   D  — accepted by server on decode (we must also accept)
#   D* — decode-only (peer SDKs may emit; server never does)
#
# Cross-references annotate `convert.rs:NNN` for each tag's decode arm.

# IANA-standard tags
const TAG_SPEC_DATETIME    = UInt64(0)   # D*   text (ISO 8601)            convert.rs:68
const TAG_SPEC_UUID        = UInt64(37)  # E/D  bytes (16 raw)             convert.rs:114

# SurrealDB custom (6..15 unassigned IANA range)
const TAG_NONE             = UInt64(6)   # E/D  Null                       convert.rs:104
const TAG_TABLE            = UInt64(7)   # E/D  text                       convert.rs:188
const TAG_RECORDID         = UInt64(8)   # E/D  [table_text, key]          convert.rs:157
const TAG_STRING_UUID      = UInt64(9)   # D*   text                       convert.rs:106
const TAG_STRING_DECIMAL   = UInt64(10)  # E/D  text                       convert.rs:116
# const TAG_BINARY_DECIMAL = UInt64(11)  # reserved (commented at convert.rs:29)
const TAG_CUSTOM_DATETIME  = UInt64(12)  # E/D  [i64 sec, u32 nanos]       convert.rs:76
const TAG_STRING_DURATION  = UInt64(13)  # D*   text (ISO 8601 e.g. "1h30m") convert.rs:124
const TAG_CUSTOM_DURATION  = UInt64(14)  # E/D  [] / [secs] / [secs,nanos] convert.rs:132
# const TAG_FUTURE         = UInt64(15)  # reserved (legacy; convert.rs:33-35)

# Ranges (49..51 unassigned IANA range)
const TAG_RANGE            = UInt64(49)  # E/D  [start_bound, end_bound]   convert.rs:193
const TAG_BOUND_INCLUDED   = UInt64(50)  # E/D  nested value               convert.rs:514
const TAG_BOUND_EXCLUDED   = UInt64(51)  # E/D  nested value               convert.rs:515

# File + Set (55..60 unassigned IANA range)
const TAG_FILE             = UInt64(55)  # E/D  [bucket_text, key_text]   convert.rs:337
const TAG_SET              = UInt64(56)  # E/D  array (BTreeSet on server) convert.rs:353

# Geometry (88..94 unassigned IANA range)
const TAG_GEOMETRY_POINT         = UInt64(88)   # E/D  [f64 x, f64 y]           convert.rs:194
const TAG_GEOMETRY_LINE          = UInt64(89)   # E/D  array of Tag(88)         convert.rs:222
const TAG_GEOMETRY_POLYGON       = UInt64(90)   # E/D  array of Tag(89)         convert.rs:238
const TAG_GEOMETRY_MULTIPOINT    = UInt64(91)   # E/D  array of Tag(88)         convert.rs:269
const TAG_GEOMETRY_MULTILINE     = UInt64(92)   # E/D  array of Tag(89)         convert.rs:287
const TAG_GEOMETRY_MULTIPOLYGON  = UInt64(93)   # E/D  array of Tag(90)         convert.rs:305
const TAG_GEOMETRY_COLLECTION    = UInt64(94)   # E/D  array of any geometry tag convert.rs:323
