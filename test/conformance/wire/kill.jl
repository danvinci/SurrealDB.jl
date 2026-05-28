#!/usr/bin/env julia
# kill.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# live then kill; confirm subsequent CREATE produces no notification.
#
# Run: julia --project=test test/conformance/wire/kill.jl

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

function test_kill()
    c = fresh_client(run_id())
    try
        SurrealDB.query(c, "DEFINE TABLE killme SCHEMALESS")
        sub = SurrealDB.live(c, "killme")
        child = SurrealDB.subscribe(sub)
        chan = child.channel
        SurrealDB.kill!(sub)
        # CREATE; subscribe channel should NOT receive
        @async begin
            sleep(0.05)
            try; SurrealDB.create(c, "killme", Dict("name" => "ghost")); catch; end
        end
        sleep(1.0)
        if isready(chan)
            v = take!(chan)
            return (:fail, "unexpected notification after kill: $v")
        end
        return (:pass, "kill prevented further notifications")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_kill()
    println(rpad("kill", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
