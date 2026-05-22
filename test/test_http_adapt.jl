# Unit tests for _http_adapt_method — pure SurrealQL-rewrite path on the
# HTTP transport. No server needed; tests the function in isolation.
#
# Each branch must (a) apply the USE NS/DB prefix when present, (b) bind
# user-supplied identifiers as variables to avoid SQL-injection on the
# parameter values, and (c) leave non-data RPC methods unchanged.

using SurrealDB
using Test

const _adapt = SurrealDB._http_adapt_method
const _NSDB = "USE NS test DB test;\n"

@testset "empty prefix → passthrough" begin
    method, params = _adapt("select", Any["foo"], "")
    @test method == "select"
    @test params == Any["foo"]
end

@testset "query / select / create / update / delete" begin
    @test _adapt("query", Any["SELECT 1"], _NSDB) ==
        ("query", Any[_NSDB * "SELECT 1", Dict{String,Any}()])

    @test _adapt("select", Any["users"], _NSDB) ==
        ("query", Any[_NSDB * "SELECT * FROM users", Dict{String,Any}()])

    m, p = _adapt("create", Any["users", Dict("name" => "alice")], _NSDB)
    @test m == "query"
    @test p[1] == _NSDB * "CREATE users CONTENT \$data"
    @test p[2] == Dict("data" => Dict("name" => "alice"))

    m, p = _adapt("update", Any["users:1", Dict("v" => 2)], _NSDB)
    @test occursin("UPDATE users:1 MERGE \$data", p[1])

    @test _adapt("delete", Any["users:1"], _NSDB) ==
        ("query", Any[_NSDB * "DELETE FROM users:1", Dict{String,Any}()])
end

@testset "insert / upsert / merge" begin
    m, p = _adapt("insert", Any["users", Dict("name" => "bob")], _NSDB)
    @test occursin("INSERT INTO users \$data", p[1])

    m, p = _adapt("upsert", Any["users:1", Dict("x" => 1)], _NSDB)
    @test occursin("UPSERT users:1 CONTENT \$data", p[1])

    m, p = _adapt("merge", Any["users:1", Dict("y" => 2)], _NSDB)
    @test occursin("UPDATE users:1 MERGE \$data", p[1])
end

@testset "relate / insert_relation" begin
    m, p = _adapt("relate", Any["person:a", "knows", "person:b", Dict("met" => "today")], _NSDB)
    @test m == "query"
    @test occursin("RELATE person:a->knows->person:b CONTENT \$data", p[1])
    @test p[2] == Dict("data" => Dict("met" => "today"))

    m, p = _adapt("insert_relation", Any["knows", Dict("in" => "a", "out" => "b")], _NSDB)
    @test occursin("INSERT INTO knows \$data", p[1])
end

@testset "patch — JSON Patch ops → UPDATE PATCH" begin
    patches = [Dict("op" => "replace", "path" => "/n", "value" => 7)]
    m, p = _adapt("patch", Any["users:1", patches], _NSDB)
    @test m == "query"
    @test p[1] == _NSDB * "UPDATE users:1 PATCH \$patches"
    @test p[2] == Dict("patches" => patches)

    # diff=true appends RETURN DIFF
    m, p = _adapt("patch", Any["users:1", patches, true], _NSDB)
    @test occursin("PATCH \$patches RETURN DIFF", p[1])
end

@testset "run — fn:: rewrite + positional arg binding" begin
    m, p = _adapt("run", Any["fn::adder", nothing, Any[1, 2]], _NSDB)
    @test m == "query"
    @test p[1] == _NSDB * "RETURN fn::adder(\$arg0, \$arg1)"
    @test p[2] == Dict("arg0" => 1, "arg1" => 2)

    # No-arg call
    m, p = _adapt("run", Any["fn::now", nothing, Any[]], _NSDB)
    @test p[1] == _NSDB * "RETURN fn::now()"
    @test isempty(p[2])

    # Function-name validation: anything outside identifier/`::` shape rejected.
    @test_throws ArgumentError _adapt("run", Any["fn; DROP TABLE x", nothing, Any[]], _NSDB)
    @test_throws ArgumentError _adapt("run", Any["fn::name; --", nothing, Any[]], _NSDB)
end

@testset "live → UnsupportedFeatureError" begin
    @test_throws SurrealDB.UnsupportedFeatureError _adapt("live", Any["users", false], _NSDB)
end

@testset "non-data methods pass through" begin
    @test _adapt("signin", Any[Dict("user" => "x")], _NSDB) ==
        ("signin", Any[Dict("user" => "x")])
    @test _adapt("authenticate", Any["tok"], _NSDB) ==
        ("authenticate", Any["tok"])
    @test _adapt("use", Any["ns", "db"], _NSDB) ==
        ("use", Any["ns", "db"])
    @test _adapt("version", Any[], _NSDB) ==
        ("version", Any[])
end
