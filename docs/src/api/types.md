# Types

Auto-generated from docstrings. For narrative usage, see the [Guide](../index.md#Guide).

## Core types

```@docs
SurrealDB.RecordID
SurrealDB.StringRecordID
SurrealDB.@rid_str
SurrealDB.SurrealThing
SurrealDB.Table
SurrealDB.SurrealValue
SurrealDB.Relationship
```

See [Record IDs](../records.md) for the three id forms and the colon-string guard.

## Wire-format types

```@docs
SurrealDB.SurrealDecimal
SurrealDB.SurrealDateTime
SurrealDB.SurrealDuration
SurrealDB.SurrealFile
SurrealDB.SurrealRange
SurrealDB.BoundIncluded
SurrealDB.BoundExcluded
SurrealDB.GeometryPoint
SurrealDB.GeometryLine
SurrealDB.GeometryPolygon
SurrealDB.GeometryMultiPoint
SurrealDB.GeometryMultiLine
SurrealDB.GeometryMultiPolygon
SurrealDB.GeometryCollection
```

See [Wire format](../wire.md) for the CBOR / JSON contract and the NONE / NULL → `missing` / `nothing` mapping.

## Tables.jl and graph extensions

```@docs
SurrealDB.to_table
SurrealDB.to_metagraph
SurrealDB.QueryResultTable
```
