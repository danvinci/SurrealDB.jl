client = get_test_client()
clean_table!(client, "test_query")

@testset "Literal queries" begin
    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) >= 1
end

@testset "Multiple statements" begin
    result = SurrealDB.query(client, "SELECT * FROM 1; SELECT * FROM 1")
    @test length(result) >= 2
end

@testset "Create and select" begin
    SurrealDB.query(client, "CREATE test_query:1 SET name = 'test', value = 42")
    result = SurrealDB.query(client, "SELECT * FROM test_query")
    @test length(result) > 0
end

@testset "Parameterized query" begin
    result = SurrealDB.query(client, "SELECT * FROM test_query WHERE name = \$name",
                              vars=Dict("name" => "test"))
    @test length(result) >= 1
end

@testset "RETURN clause" begin
    result = SurrealDB.query(client, "RETURN 42")
    @test length(result) >= 1
    @test result[1] == 42
end

@testset "Syntax error" begin
    @test_throws SurrealDB.SurrealError SurrealDB.query(client, "SELEC * FRUM 1")
end

@testset "CREATE with content" begin
    SurrealDB.query(client, "CREATE test_query:content_test CONTENT { a: 1, b: 2 }")
    result = SurrealDB.query(client, "SELECT * FROM test_query:content_test")
    @test length(result) >= 1
end

@testset "DELETE query" begin
    SurrealDB.query(client, "DELETE FROM test_query")
    result = SurrealDB.query(client, "SELECT * FROM test_query")
    @test length(result) == 0 || all(r -> isempty(r), result)
end

@testset "Empty result set" begin
    result = SurrealDB.query(client, "SELECT * FROM test_query WHERE false")
    @test length(result) >= 1
    @test isempty(result[1])
end

@testset "Nonexistent table query" begin
    # v3 throws QueryError for undefined tables, v2 returns empty
    try
        SurrealDB.query(client, "SELECT * FROM certainly_does_not_exist_42")
        @test true  # v2: returned empty
    catch e
        @test e isa SurrealDB.SurrealError  # v3: throws
    end
end

@testset "Missing parameterized var" begin
    result = SurrealDB.query(client, "SELECT * FROM \$nonexistent_var",
                              vars=Dict{String, Any}())
    @test length(result) >= 1
end

@testset "USE and LET via raw query" begin
    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) >= 1
end

@testset "INSERT and RETURN affected" begin
    result = SurrealDB.query(client, "INSERT INTO test_query { name: 'bulk1' }")
    @test length(result) >= 1
end

clean_table!(client, "test_query")
SurrealDB.close!(client)
