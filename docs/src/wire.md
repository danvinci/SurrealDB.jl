# Wire format

CBOR is the default wire format.
JSON is available as an opt-in:

```julia
SurrealDB.connect("ws://localhost:8000"; wire=:cbor)   # default
SurrealDB.connect("ws://localhost:8000"; wire=:json)
```

## CBOR

Typed values round-trip without loss:
[`RecordID`](@ref), [`Table`](@ref), [`SurrealDecimal`](@ref), nanosecond [`SurrealDateTime`](@ref) and [`SurrealDuration`](@ref), [`SurrealFile`](@ref), [`SurrealRange`](@ref), all seven `Geometry*` shapes.
Encoding parity is checked against the server's CBOR crate (`ciborium`) via fixture round-trips.

## JSON

Typed values lower to canonical strings:

- `RecordID` → `"table:id"`
- `Table` → `"name"`
- `SurrealDecimal` → numeric string
- `SurrealDateTime` → ISO 8601 with 9-digit fractional seconds
- `SurrealDuration` → SurrealQL compact form (`42s500ns`)
- `Geometry*` → GeoJSON object
- `SurrealRange` → structured `{start, stop}` with `inclusive` flags

JSON loses type information on decode: a `RecordID` arrives back as a `String`, a `SurrealDateTime` as an ISO string.
Use CBOR for full type fidelity; use JSON for debug or legacy peers.

## NONE vs NULL

SurrealDB distinguishes two no-value sentinels:

- `NONE` — field is unset / does not exist
- `NULL` — field is explicitly set to null

The SDK preserves the distinction via Julia's two no-value types:

| SurrealDB | Julia | Wire (CBOR) |
|---|---|---|
| `NONE` | `missing` | `Tag(6, null)` |
| `NULL` | `nothing` | bare null |

On read, expect either:

```julia
result = SurrealDB.query(db, "RETURN \$maybe_unset")
isnothing(result[1]) || ismissing(result[1])
```

On write, both Julia sentinels round-trip semantically:

```julia
SurrealDB.create(db, "tbl", Dict("x" => missing))    # server stores NONE
SurrealDB.create(db, "tbl", Dict("x" => nothing))    # server stores NULL
```

The mapping is stable across SurrealDB v2.0.0 → v3.x.
