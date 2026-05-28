using SurrealDB
using StructTypes
using Test

client = get_test_client()

struct TestUser
    id::Any
    username::String
    password::String
end
StructTypes.StructType(::Type{TestUser}) = StructTypes.Struct()

struct TestEdge
    id::Any
    rel_in::Any
    rel_out::Any
    since::String
end
StructTypes.StructType(::Type{TestEdge}) = StructTypes.Struct()

function _clean_struct!(c, table::String)
    try SurrealDB.query(c, "DELETE FROM $table") catch; end
end

@testset "Typed create with StructTypes" begin
    _clean_struct!(client, "test_port")
    try SurrealDB.create(client, rid"test_port:__init", Dict("_init" => true)); catch; end

    user = SurrealDB.create(client, TestUser, rid"test_port:typed",
        Dict("username" => "alice", "password" => "secret"))
    @test user isa TestUser
    @test user.username == "alice"
    @test user.password == "secret"

    _clean_struct!(client, "test_port")
end

@testset "Typed select with StructTypes" begin
    SurrealDB.create(client, rid"test_port:typed_select",
        Dict("username" => "bob", "password" => "pwd"))

    user = SurrealDB.select(client, TestUser, rid"test_port:typed_select")
    @test user isa TestUser
    @test user.username == "bob"
    @test user.password == "pwd"

    users = SurrealDB.select(client, TestUser, "test_port")
    @test users isa Vector
    @test all(u -> u isa TestUser, users)
    @test length(users) >= 1

    _clean_struct!(client, "test_port")
end

@testset "Typed query with StructTypes" begin
    SurrealDB.create(client, "test_port", Dict("username" => "carol", "password" => "xyz"))
    SurrealDB.create(client, "test_port", Dict("username" => "dave", "password" => "abc"))

    users = SurrealDB.query(client, TestUser, "SELECT * FROM test_port ORDER BY username")
    @test users isa Vector{TestUser}
    @test length(users) >= 2
    # `id` arrives as typed `RecordID` post-s13 type fidelity (CBOR Tag(8)).
    @test users[1].id isa RecordID
    @test users[1].id.table == "test_port"

    _clean_struct!(client, "test_port")
end

@testset "Typed insert with StructTypes" begin
    user = SurrealDB.create(client, TestUser, rid"test_port:irt",
        Dict("username" => "eve", "password" => "555"))
    @test user isa TestUser
    @test user.username == "eve"
    @test user.id == rid"test_port:irt"

    _clean_struct!(client, "test_port")
end
