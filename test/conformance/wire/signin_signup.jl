#!/usr/bin/env julia
# signin_signup.jl
#
# Hand-translated wire-protocol test from upstream tests/ws_integration.rs:
# root signin via SDK; then signup a record-access user.
#
# Run: julia --project=test test/conformance/wire/signin_signup.jl

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

function test_signin_signup()
    suffix = run_id()
    c = fresh_client(suffix)
    try
        # already signed in as root via connect(); verify info
        SurrealDB.query(c, "DEFINE ACCESS account ON DB TYPE RECORD " *
            "SIGNUP ( CREATE user SET email = \$email, pass = crypto::argon2::generate(\$pass) ) " *
            "SIGNIN ( SELECT * FROM user WHERE email = \$email AND " *
            "crypto::argon2::compare(pass, \$pass) ) " *
            "DURATION FOR SESSION 5m, FOR TOKEN 30s;")
        # signup user
        c2 = SurrealDB.connect(URL; ns="wire_$suffix", db="wire_$suffix", auth=nothing)
        SurrealDB.signup!(c2, SurrealDB.ScopedAuth(
            "wire_$suffix", "wire_$suffix", "account",
            Dict("email" => "alice@example.com", "pass" => "hunter2")))
        SurrealDB.close!(c2)
        # signin same user
        c3 = SurrealDB.connect(URL; ns="wire_$suffix", db="wire_$suffix", auth=nothing)
        SurrealDB.signin!(c3, SurrealDB.ScopedAuth(
            "wire_$suffix", "wire_$suffix", "account",
            Dict("email" => "alice@example.com", "pass" => "hunter2")))
        SurrealDB.close!(c3)
        return (:pass, "signup+signin round-trip ok")
    catch e
        return (:fail, sprint(showerror, e))
    finally
        SurrealDB.close!(c)
    end
end

function main()
    status, detail = test_signin_signup()
    println(rpad("signin_signup", 22), uppercase(string(status)), "  ", detail)
    status == :pass || exit(1)
end

main()
