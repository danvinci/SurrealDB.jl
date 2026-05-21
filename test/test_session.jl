using UUIDs

client = get_test_client()

@testset "Set variable" begin
    SurrealDB.let!(client, "test_var", 42)
    @test client.variables["test_var"] == 42
end

@testset "Use variable in query" begin
    SurrealDB.let!(client, "query_test_var", 42)
    result = SurrealDB.query(client, "RETURN \$query_test_var")
    @test length(result) >= 1
    @test result[1] == 42
    SurrealDB.unset!(client, "query_test_var")
end

@testset "Overwrite variable" begin
    SurrealDB.let!(client, "test_var", "new_value")
    @test client.variables["test_var"] == "new_value"
end

@testset "Unset variable" begin
    SurrealDB.unset!(client, "test_var")
    @test !haskey(client.variables, "test_var")
end

@testset "Multiple variables" begin
    SurrealDB.let!(client, "a", 1)
    SurrealDB.let!(client, "b", 2)
    result = SurrealDB.query(client, "RETURN \$a + \$b")
    @test length(result) >= 1
    @test result[1] == 3
    SurrealDB.unset!(client, "a")
    SurrealDB.unset!(client, "b")
end

@testset "Variables survive use! reselection" begin
    SurrealDB.let!(client, "persist", "val")
    SurrealDB.use!(client, TEST_NS, TEST_DB)
    @test client.variables["persist"] == "val"
    SurrealDB.unset!(client, "persist")
end

@testset "Variables isolated across connections" begin
    client2 = get_test_client()
    SurrealDB.let!(client, "isolated_test", "visible_only_here")

    result = SurrealDB.query(client, "RETURN \$isolated_test")
    @test length(result) >= 1
    @test result[1] == "visible_only_here"

    # v2: other client cannot see variable (throws)
    # v3: undefined vars are nil, no error
    result2 = SurrealDB.query(client2, "RETURN \$isolated_test")
    @test result2[1] === nothing || result2[1] isa Nothing

    SurrealDB.unset!(client, "isolated_test")
    SurrealDB.close!(client2)
end

@testset "Variable with Dict value" begin
    data = Dict("a" => 1, "b" => "two")
    SurrealDB.let!(client, "dict_var", data)
    result = SurrealDB.query(client, "SELECT * FROM \$dict_var")
    @test length(result) >= 1
    SurrealDB.unset!(client, "dict_var")
end

@testset "Variable with Vector value" begin
    vals = [10, 20, 30]
    SurrealDB.let!(client, "vec_var", vals)
    result = SurrealDB.query(client, "SELECT * FROM \$vec_var")
    @test length(result) >= 1
    SurrealDB.unset!(client, "vec_var")
end

# --- v3+ Sessions (attach/detach) ---

@testset "attach!/detach!/sessions roundtrip (v3+)" begin
    # v2 doesn't implement the attach RPC; gate via version probe.
    ver = try; string(SurrealDB.version(client)); catch; ""; end
    if occursin(r"surrealdb-2\.", ver)
        @info "Skipping attach!/detach! — v2 server doesn't support v3 sessions"
    else
        sid = SurrealDB.attach!(client)
        @test sid isa UUIDs.UUID
        @test sid in SurrealDB.sessions(client)
        SurrealDB.detach!(client, sid)
        @test !(sid in SurrealDB.sessions(client))
    end
end

@testset "attach! is WS-only — MethodError on HTTP" begin
    # Dispatch-only check: attach! is gated on RemoteWSConnection.
    http_url = replace(TEST_URL, "ws://" => "http://", "wss://" => "https://")
    http_client = SurrealDB.connect(http_url; ns=TEST_NS, db=TEST_DB,
                                    auth=SurrealDB.RootAuth("root", "root"))
    try
        @test_throws MethodError SurrealDB.attach!(http_client)
    finally
        SurrealDB.close!(http_client)
    end
end

SurrealDB.close!(client)
sleep(0.5)  # Let reconnect loop exit before other tests connect
