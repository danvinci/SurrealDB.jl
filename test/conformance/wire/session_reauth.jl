#!/usr/bin/env julia
# session_reauth.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# session reauthentication: signin with a token after invalidate.
#
# Run: julia --project=test test/conformance/wire/session_reauth.jl

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

function test_session_reauth()
    suffix = run_id()
    c = fresh_client(suffix)
    try
        SurrealDB.invalidate!(c)
        # now no auth; signin again as root
        SurrealDB.signin!(c, SurrealDB.RootAuth("root", "root"))
        SurrealDB.use!(c, "wire_$suffix", "wire_$suffix")
        SurrealDB.query(c, "CREATE reauth:1 SET v = 1")
        sel = SurrealDB.select(c, "reauth")
        return length(sel) == 1 ? (:pass, "reauthenticated ok") :
                                  (:fail, "select after reauth: $sel")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_session_reauth()
    println(rpad("session_reauth", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
