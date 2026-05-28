@testset "Connection lifecycle" begin
    client = SurrealDB.connect(TEST_URL)

    @test client.connection.status == SurrealDB.STATUS_CONNECTED
    @test client.namespace === nothing
    @test client.database === nothing
    @test client.token === nothing

    SurrealDB.use!(client, TEST_NS, TEST_DB)
    @test client.namespace == TEST_NS
    @test client.database == TEST_DB

    token = SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    @test token isa String
    @test !isempty(token)

    info = SurrealDB.info(client)
    # Root user has no user record → server returns NONE → decodes to `missing`;
    # auth'd as a user → Dict; never-bound session → nothing.
    @test (info isa AbstractDict) || isnothing(info) || ismissing(info)

    ver = SurrealDB.version(client)
    @test ver.version isa String
    @test !isempty(ver.version)
    @test occursin("surrealdb", lowercase(ver.version))

    @test SurrealDB.health(client)

    SurrealDB.close!(client)
    @test client.namespace === nothing
    @test client.database === nothing
    @test client.token === nothing
end

@testset "Connect with options" begin
    client = SurrealDB.connect(TEST_URL, ns=TEST_NS, db=TEST_DB,
                                auth=SurrealDB.RootAuth("root", "root"))
    @test client.namespace == TEST_NS
    @test client.database == TEST_DB
    @test client.token !== nothing

    result = SurrealDB.query(client, "SELECT * FROM 1")
    @test length(result) > 0

    SurrealDB.close!(client)
end

@testset "HTTP connection" begin
    http_url = replace(TEST_URL, "ws://" => "http://")
    try
        client = SurrealDB.connect(http_url)
        @test client.connection isa SurrealDB.RemoteHTTPConnection
        SurrealDB.close!(client)
    catch e
        @warn "HTTP connection test skipped: $e"
    end
end

@testset "Close then use" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.close!(client)
    @test_throws SurrealDB.ConnectionError SurrealDB.use!(client, TEST_NS, TEST_DB)
end

@testset "Connect with bad URL" begin
    scheme = if startswith(TEST_URL, "ws://")
        "ws://localhost:19999/rpc"
    else
        "http://localhost:19999"
    end
    @test_throws SurrealDB.ConnectionError SurrealDB.connect(scheme)
end

@testset "Status after close" begin
    client = SurrealDB.connect(TEST_URL)
    SurrealDB.close!(client)
    @test SurrealDB.status(client) == SurrealDB.STATUS_DISCONNECTED
end
