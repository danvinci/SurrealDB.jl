# No server required — exercises QueryStatement, query_verbose parser path,
# isok/iserr predicates, and Base.show against raw response-shaped Dicts.

using SurrealDB: _parse_query_results, _to_query_statements, _parse_query_error,
                 QueryStatement, isok, iserr,
                 NotFoundError, QueryError, ValidationError
using Test

# Build a raw server-response vector (the shape _parse_query_results consumes).
function _ok_raw(result; time="0.1ms")
    Dict{String,Any}("status" => "OK", "time" => time, "result" => result)
end

function _err_raw(message; time="0.2ms", kind=nothing, details=nothing)
    d = Dict{String,Any}("status" => "ERR", "time" => time, "result" => message)
    isnothing(kind)    || (d["kind"] = kind)
    isnothing(details) || (d["details"] = details)
    d
end

function parse_verbose(raw_vec)
    _to_query_statements(_parse_query_results(raw_vec))
end

@testset "single-statement success" begin
    rows = [Dict{String,Any}("id" => "user:1", "name" => "Alice")]
    stmts = parse_verbose([_ok_raw(rows; time="1.2ms")])

    @test length(stmts) == 1
    s = stmts[1]
    @test s isa QueryStatement
    @test isok(s)
    @test !iserr(s)
    @test s.status === :ok
    @test s.time == "1.2ms"
    @test s.result == rows
    @test isnothing(s.error)
end

@testset "multi-statement mixed: middle one errors" begin
    raw = [
        _ok_raw([Dict{String,Any}("x" => 1)]; time="0.5ms"),
        _err_raw("record not found"; time="1.0ms",
                 kind="NotFound",
                 details=Dict{String,Any}("table_name" => "user")),
        _ok_raw([Dict{String,Any}("x" => 2)]; time="0.3ms"),
    ]
    stmts = parse_verbose(raw)

    @test length(stmts) == 3

    @test isok(stmts[1])
    @test stmts[1].time == "0.5ms"
    @test isnothing(stmts[1].error)

    @test iserr(stmts[2])
    @test !isok(stmts[2])
    @test stmts[2].status === :err
    @test stmts[2].time == "1.0ms"
    @test stmts[2].error isa NotFoundError
    @test (stmts[2].error::NotFoundError).table_name == "user"
    @test isnothing(stmts[2].result)

    @test isok(stmts[3])
    @test stmts[3].time == "0.3ms"
end

@testset "empty multi-statement returns empty vector" begin
    stmts = parse_verbose(Any[])
    @test stmts isa Vector{QueryStatement}
    @test isempty(stmts)
end

@testset "isok / iserr predicate discrimination" begin
    raw = [
        _ok_raw(nothing; time="0ms"),
        _err_raw("bad"; time="0ms"),
        _ok_raw([]; time="0ms"),
        _err_raw("also bad"; time="0ms"),
    ]
    stmts = parse_verbose(raw)
    @test count(isok, stmts) == 2
    @test count(iserr, stmts) == 2
    @test filter(isok, stmts) == [stmts[1], stmts[3]]
    @test filter(iserr, stmts) == [stmts[2], stmts[4]]
end

@testset "Base.show does not crash" begin
    ok_stmt = parse_verbose([_ok_raw([1, 2, 3]; time="1.5ms")])[1]
    err_stmt = parse_verbose([_err_raw("oops"; time="2.0ms",
                                       kind="NotFound",
                                       details=Dict{String,Any}("table_name" => "t"))])[1]

    ok_str = sprint(show, ok_stmt)
    @test occursin(":ok", ok_str)
    @test occursin("1.5ms", ok_str)
    @test occursin("rows=3", ok_str)

    err_str = sprint(show, err_stmt)
    @test occursin(":err", err_str)
    @test occursin("2.0ms", err_str)
end

@testset "times are preserved verbatim" begin
    times = ["0.001ms", "123.456µs", "1s", ""]
    raw = [_ok_raw(nothing; time=t) for t in times]
    stmts = parse_verbose(raw)
    @test [s.time for s in stmts] == times
end

@testset "error field is a typed ServerError subtype" begin
    raw = [
        _err_raw("record not found"; time="1ms",
                 kind="NotFound",
                 details=Dict{String,Any}("table_name" => "event")),
        _err_raw("invalid field"; time="1ms",
                 kind="Validation",
                 details=Dict{String,Any}()),
        _err_raw("legacy error message"; time="1ms"),   # no kind → QueryError
    ]
    stmts = parse_verbose(raw)
    @test stmts[1].error isa NotFoundError
    @test stmts[2].error isa ValidationError
    @test stmts[3].error isa QueryError
    for s in stmts
        @test s.error isa SurrealDB.ServerError
    end
end

@testset "show: nil result ok statement" begin
    s = parse_verbose([_ok_raw(nothing; time="0ms")])[1]
    str = sprint(show, s)
    @test occursin(":ok", str)
    @test occursin("result=nothing", str)
end

# --- Optional server-gated integration ---
if get(ENV, "SERVER_AVAILABLE", "false") == "true"
    @testset "integration: multi-statement partial failure" begin
        using SurrealDB
        db = connect("ws://localhost:8000", namespace="test", database="test")
        signin!(db, RootAuth("root", "root"))

        # Ensure clean state
        query(db, "DELETE user:dup_test")

        stmts = query_verbose(db, """
            INSERT INTO user { id: user:dup_test, name: "First" };
            INSERT INTO user { id: user:dup_test, name: "Duplicate" };
            SELECT * FROM user WHERE id = user:dup_test;
        """)

        @test length(stmts) == 3
        @test isok(stmts[1])
        @test iserr(stmts[2])
        @test isok(stmts[3])
        # First insert result survives independently of second failure
        @test stmts[1].result isa AbstractVector
        @test !isempty(stmts[1].result)
        # Third select sees the one successfully inserted row
        @test length(stmts[3].result) == 1

        close!(db)
    end
end
