#!/usr/bin/env julia
# crud.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# CRUD round-trip: create then select via dedicated RPCs (not raw query).
#
# Run: julia --project=test test/conformance/wire/crud.jl

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

function test_crud()
    c = fresh_client(run_id())
    try
        rec = SurrealDB.create(c, "task", Dict("title" => "buy milk", "done" => false))
        rid = if rec isa AbstractVector && !isempty(rec); rec[1]["id"]
              elseif rec isa AbstractDict; rec["id"]
              else; nothing end
        sel = SurrealDB.select(c, "task")
        if length(sel) != 1
            return (:fail, "select returned $(length(sel)) rows, expected 1; rid=$rid; sel=$(sel)")
        end
        # update field
        SurrealDB.merge(c, rid, Dict("done" => true))
        sel2 = SurrealDB.select(c, rid)
        ok = sel2 isa AbstractDict ? get(sel2, "done", nothing) == true :
             (sel2 isa AbstractVector && !isempty(sel2) && get(sel2[1], "done", nothing) == true)
        return ok ? (:pass, "crud round-trip ok") :
                    (:fail, "post-merge `done` not true: $sel2")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_crud()
    println(rpad("crud", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
