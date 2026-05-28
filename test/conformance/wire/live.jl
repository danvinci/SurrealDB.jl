#!/usr/bin/env julia
# live.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# live query: subscribe to a table; CREATE on it; receive notification.
#
# Run: julia --project=test test/conformance/wire/live.jl

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

function test_live_query()
    c = fresh_client(run_id())
    try
        # Ensure table exists (server requires it for LIVE)
        SurrealDB.query(c, "DEFINE TABLE stream SCHEMALESS")
        sub = SurrealDB.live(c, "stream")
        # CREATE in a separate task (same connection is fine here)
        @async begin
            sleep(0.1)
            try
                SurrealDB.create(c, "stream", Dict("name" => "river"))
            catch
            end
        end
        # wait for one notification
        got = nothing
        child = SurrealDB.subscribe(sub)
        chan = child.channel
        t0 = time()
        while time() - t0 < 5.0
            if isready(chan)
                got = take!(chan)
                break
            end
            sleep(0.05)
        end
        SurrealDB.kill!(sub)
        if got === nothing
            return (:fail, "no live notification within 5s")
        end
        return (:pass, "live notification action=$(got.action)")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_live_query()
    println(rpad("live_query", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
