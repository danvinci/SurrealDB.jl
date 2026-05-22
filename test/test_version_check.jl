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
