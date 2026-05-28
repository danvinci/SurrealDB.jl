# Reverse interop fixture: Julia writes the same set of records that the
# Python writer produces. The Python reader (`read_test_data.py`) then
# verifies them. Catches our serialization drift — symmetric to the
# Python-writes-Julia-reads test in test_interop.jl.

using SurrealDB

const URL = get(ENV, "SURREALDB_URL", "ws://localhost:8000")
const NS = get(ENV, "SURREALDB_NS", "test")
const DB_NAME = get(ENV, "SURREALDB_DB", "test")

function main()
    db = SurrealDB.connect(URL; ns=NS, db=DB_NAME,
        auth=SurrealDB.RootAuth("root", "root"))

    try; SurrealDB.query(db, "REMOVE TABLE IF EXISTS interop_jl"); catch; end
    SurrealDB.query(db, "DEFINE TABLE interop_jl")

    fixtures = [
        ("int_pos",        "int_positive",   12345),
        ("int_neg",        "int_negative",   -67890),
        ("float_simple",   "float_simple",   3.14159),
        ("string_ascii",   "string_ascii",   "hello world"),
        ("string_unicode", "string_unicode", "αβγ ✓ 中文 🦀"),
        ("bool_true",      "bool_true",      true),
        ("bool_false",     "bool_false",     false),
        ("null",           "null_value",     nothing),
        ("array_int",      "array_int",      [1, 2, 3, 4, 5]),
        ("array_mixed",    "array_mixed",    Any[1, "two", 3.0, true, nothing]),
        ("nested_object",  "nested_object",  Dict(
            "outer" => Dict(
                "inner" => Any[10, 20, Dict("deep" => "leaf")],
                "ts" => "2024-01-15T12:30:45Z",
            ),
        )),
    ]

    for (id, kind, value) in fixtures
        rec = SurrealDB.RecordID("interop_jl", id)
        SurrealDB.create(db, rec, Dict("kind" => kind, "value" => value))
        @info "wrote" id=id
    end

    SurrealDB.close!(db)
    println("wrote $(length(fixtures)) interop_jl fixtures")
end

main()
