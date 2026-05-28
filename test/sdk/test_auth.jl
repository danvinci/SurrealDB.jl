@testset "Root signin" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    token = SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    @test token isa String
    @test !isempty(token)
    @test client.token == token

    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) > 0

    SurrealDB.close!(client)
end

@testset "Invalidate and re-authenticate" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    token = SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))

    SurrealDB.invalidate!(client)
    @test client.token === nothing

    SurrealDB.authenticate!(client, token)
    @test client.token == token

    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) > 0

    SurrealDB.close!(client)
end

@testset "Dict auth" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    token = SurrealDB.signin!(client, Dict("user" => "root", "pass" => "root"))
    @test token isa String
    @test !isempty(token)

    SurrealDB.close!(client)
end

@testset "Bad credentials" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    @test_throws SurrealDB.SurrealError SurrealDB.signin!(client,
        SurrealDB.RootAuth("root", "this_is_not_the_password"))

    SurrealDB.close!(client)
end

@testset "Signin twice invalidates first session" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    token1 = SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    token2 = SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))

    @test token1 != token2
    @test client.token == token2

    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) > 0

    SurrealDB.close!(client)
end

@testset "Authenticate with bad token" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, TEST_NS, TEST_DB)

    @test_throws SurrealDB.SurrealError SurrealDB.authenticate!(client, "not_a_valid_token_at_all")

    SurrealDB.close!(client)
end

@testset "Invalidate without auth is no-op" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.invalidate!(client)
    @test client.token === nothing

    # Should still be able to use with auth afterward
    SurrealDB.use!(client, TEST_NS, TEST_DB)
    SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    @test client.token !== nothing

    SurrealDB.close!(client)
end

@testset "Auto-signin via connect options" begin
    client = SurrealDB.connect(TEST_URL, ns=TEST_NS, db=TEST_DB,
                                auth=SurrealDB.RootAuth("root", "root"))
    @test client.token !== nothing
    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) > 0
    SurrealDB.close!(client)
end
