#!/usr/bin/env julia
# multi_statement.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# a single query() call with 3 statements.
#
# Run: julia --project=test test/conformance/wire/multi_statement.jl

using SurrealDB
using JSON
using Sockets

const URL = "ws://127.0.0.1:8000"
const AUTH = SurrealDB.RootAuth("root", "root")

run_id() = string(rand(UInt32); base = 36)

function fresh_client(suffix::String)
    ns = "wire_" * suffix
    db = "wire_" * suffix
    SurrealDB.connect(URL; ns=ns, db=db, auth=AUTH)
end

function test_multi_statement()
    c = fresh_client(run_id())
    try
        sql = "CREATE thing:1 SET v = 10; CREATE thing:2 SET v = 20; SELECT * FROM thing;"
        stmts = SurrealDB.query_verbose(c, sql)
        if length(stmts) != 3
            return (:fail, "expected 3 statements, got $(length(stmts))")
        end
        for s in stmts
            if !SurrealDB.isok(s)
                return (:fail, "stmt err: $(s.error)")
            end
        end
        last = stmts[end].result
        n = last isa AbstractVector ? length(last) : (-1)
        return n == 2 ? (:pass, "multi-statement returned 3 stmts, 2 rows in select") :
                        (:fail, "select returned $n rows, want 2")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_multi_statement()
    println(rpad("multi_statement", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
