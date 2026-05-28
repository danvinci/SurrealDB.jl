#!/usr/bin/env julia
# concurrency.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# N parallel queries on the same connection.
#
# Run: julia --project=test test/conformance/wire/concurrency.jl

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

function test_concurrency()
    c = fresh_client(run_id())
    try
        N = 32
        tasks = Vector{Task}(undef, N)
        results = Vector{Any}(undef, N)
        @sync for i in 1:N
            tasks[i] = @async begin
                try
                    r = SurrealDB.query(c, "SELECT * FROM { value: $i }")
                    results[i] = r
                catch e
                    results[i] = e
                end
            end
        end
        errs = [r for r in results if r isa Exception]
        if !isempty(errs)
            return (:fail, "$(length(errs))/$N parallel queries failed: e.g. $(errs[1])")
        end
        return (:pass, "$N parallel queries succeeded")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_concurrency()
    println(rpad("concurrency", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
