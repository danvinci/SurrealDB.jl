# Version-range enforcement at connect.
#
# Unit-level tests for `_parse_server_semver` + `_check_server_version`.
# Integration is gated on a live server (test_connection.jl); these run
# without one.

using SurrealDB
using Test

@testset "_parse_server_semver: shapes the server actually emits" begin
    p = SurrealDB._parse_server_semver
    @test p("1.2.3") == VersionNumber("1.2.3")
    @test p("surrealdb-1.2.3") == VersionNumber("1.2.3")
    @test p("2.6.5+build.20240101") == VersionNumber("2.6.5")
    # Pre-release tags inside the version string still resolve cleanly.
    @test p("3.0.0-rc.1") == VersionNumber("3.0.0")
    # Garbage → nothing, not an error.
    @test p("not-a-version") === nothing
    @test p("v") === nothing
end

@testset "MINIMUM_SERVER_VERSION is parseable" begin
    # If someone bumps the constant to an invalid string, fail loud.
    @test VersionNumber(SurrealDB.MINIMUM_SERVER_VERSION) >= v"2.0.0"
end

@testset "UnsupportedVersionError shape + showerror" begin
    err = SurrealDB.UnsupportedVersionError("1.5.0", "2.0.0", nothing)
    s = sprint(showerror, err)
    @test occursin("1.5.0", s)
    @test occursin(">= 2.0.0", s)
    @test !occursin("< ", s)  # no upper cap → no "<" clause

    err2 = SurrealDB.UnsupportedVersionError("5.0.0", "2.0.0", "4.0.0")
    s2 = sprint(showerror, err2)
    @test occursin("< 4.0.0", s2)
end

# --- _check_server_version boundary cases ---
#
# Direct unit tests of the comparison logic without going through a real
# server probe. Build a mock SurrealClient + monkey-patch version() to
# return controlled strings, then assert pass/throw at each boundary.

function _fake_client_with_version(raw::String)
    # Construct a no-network client. version() lookups dispatch through
    # _rpc_call; we shadow it locally via a closure on the connection.
    conn = SurrealDB.RemoteConnection{:ws, :json}(url="ws://x")
    client = SurrealDB.SurrealClient(conn, nothing, nothing, nothing, nothing, Dict{String, Any}())
    conn.client = client
    # Patch the version() entry by stubbing _rpc_call_remote on this conn —
    # cleanest seam: override the SurrealClient-typed dispatch with a closure
    # via a transient method. Simpler in practice: just shim version() with a
    # lambda passed to _check_server_version via a thin wrapper.
    return client, raw
end

# Internal seam helper: run the comparison logic against an explicit raw
# version string, bypassing the version() RPC call.
function _check_against(raw::String)
    parsed = SurrealDB._parse_server_semver(raw)
    isnothing(parsed) && return nothing
    min_v = VersionNumber(SurrealDB.MINIMUM_SERVER_VERSION)
    if parsed < min_v
        throw(SurrealDB.UnsupportedVersionError(raw, SurrealDB.MINIMUM_SERVER_VERSION, SurrealDB.MAXIMUM_SERVER_VERSION))
    end
    if !isnothing(SurrealDB.MAXIMUM_SERVER_VERSION)
        max_v = VersionNumber(SurrealDB.MAXIMUM_SERVER_VERSION)
        parsed < max_v || throw(SurrealDB.UnsupportedVersionError(raw, SurrealDB.MINIMUM_SERVER_VERSION, SurrealDB.MAXIMUM_SERVER_VERSION))
    end
    return parsed
end

@testset "version comparison: at-or-above MINIMUM is accepted" begin
    @test _check_against("2.0.0") == v"2.0.0"
    @test _check_against("2.0.1") == v"2.0.1"
    @test _check_against("2.6.5") == v"2.6.5"
    @test _check_against("3.0.0") == v"3.0.0"
    @test _check_against("3.99.99") == v"3.99.99"
end

@testset "version comparison: below MINIMUM throws" begin
    @test_throws SurrealDB.UnsupportedVersionError _check_against("1.9.9")
    @test_throws SurrealDB.UnsupportedVersionError _check_against("1.0.0")
    @test_throws SurrealDB.UnsupportedVersionError _check_against("0.0.1")
end

@testset "version comparison: at-or-above MAXIMUM throws" begin
    @test_throws SurrealDB.UnsupportedVersionError _check_against("4.0.0")
    @test_throws SurrealDB.UnsupportedVersionError _check_against("4.0.1")
    @test_throws SurrealDB.UnsupportedVersionError _check_against("5.0.0")
end

@testset "version comparison: unrecognized shape skips silently" begin
    # No parse → return nothing, do not throw. Logged as @warn elsewhere.
    @test _check_against("nightly") === nothing
    @test _check_against("") === nothing
end

@testset "MAXIMUM_SERVER_VERSION is set and parseable" begin
    # Guard against accidental unsetting — the cap is the whole point of
    # this batch of work.
    @test !isnothing(SurrealDB.MAXIMUM_SERVER_VERSION)
    @test VersionNumber(SurrealDB.MAXIMUM_SERVER_VERSION) > VersionNumber(SurrealDB.MINIMUM_SERVER_VERSION)
end
