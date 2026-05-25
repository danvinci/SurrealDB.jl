# Integrations

## Typed responses (StructTypes.jl)

Deserialize query results into typed structs:

```julia
using StructTypes

struct User
    id::SurrealDB.RecordID
    name::String
    age::Int
end
StructTypes.StructType(::Type{User}) = StructTypes.Struct()

users = SurrealDB.select(db, User, "user")
alice = SurrealDB.create(db, User, "user",
    Dict("name" => "Alice", "age" => 30))
```

The following types round-trip automatically into typed struct fields:
`RecordID`, `Date`, `DateTime`, `UUID`, `SurrealDecimal`, `SurrealDuration`, `SurrealFile`, `SurrealRange`, and the seven `Geometry*` shapes.
Nested `Dict` / `Vector` recurse into nested structs.

## Tables.jl

Query results conform to `Tables.jl`, so they plug into `DataFrames`, `CSV.jl`, `Arrow.jl`, or anything that consumes the Tables interface:

```julia
using DataFrames
result = SurrealDB.query_table(db, "SELECT name, age FROM user")
df = DataFrame(result)
```

[`query_one`](@ref) asserts a single statement and returns one table.
[`query_table`](@ref) returns one `QueryResultTable` per `;`-separated statement on remote.
The embedded backend flattens them into a single result.

## MetaGraphsNext (Pkg extension)

Loads automatically when `MetaGraphsNext` and `Graphs` are present in your environment alongside `SurrealDB`:

```julia
using SurrealDB, MetaGraphsNext, Graphs

g = SurrealDB.to_metagraph(db,
    "SELECT id, name FROM user",
    "SELECT id, in, out FROM follows")
```

Vertex labels are `RecordID` strings; vertex and edge data are field dicts.
The SDK does not auto-coerce results into a graph — pass the vertex and edge queries explicitly.

## Running user-defined functions

```julia
SurrealDB.run(db, "fn::greet", ["world"])
```

`SurrealDB.run` invokes user-defined functions (`fn::*` namespace).
Built-in SurrealQL functions like `type::is::array` are SQL-only; call them through `query()`.
