# MetaGraphsNext Pkg extension — `to_metagraph` coverage.
#
# Two paths to test:
#   1. `to_metagraph(vertices, edges)` — pure unit, no server. Locks the
#      core dispatch + label/metadata mapping.
#   2. `to_metagraph(client, vqry, eqry)` — live-server integration via the
#      mock-WS infra (deferred; the unit path covers the materialization
#      logic, the client overload is a thin wrapper around `query()`).
#
# The extension only loads when MetaGraphsNext + Graphs are both present in
# the env. test/Project.toml adds them; the extension auto-loads on the
# `using` line below.

using SurrealDB
using MetaGraphsNext
using Graphs
using Test

@testset "to_metagraph: pre-fetched vertices + edges" begin
    vertices = [
        Dict("id" => "person:alice", "name" => "Alice", "age" => 30),
        Dict("id" => "person:bob",   "name" => "Bob",   "age" => 25),
        Dict("id" => "person:carol", "name" => "Carol", "age" => 35),
    ]
    edges = [
        Dict("in" => "person:alice", "out" => "person:bob",   "since" => 2020),
        Dict("in" => "person:bob",   "out" => "person:carol", "since" => 2021),
    ]

    g = SurrealDB.to_metagraph(vertices, edges)

    @test g isa MetaGraphsNext.MetaGraph
    @test Graphs.nv(g.graph) == 3
    @test Graphs.ne(g.graph) == 2

    @test g["person:alice"]["name"] == "Alice"
    @test g["person:bob"]["age"] == 25

    @test g["person:alice", "person:bob"]["since"] == 2020
    @test g["person:bob", "person:carol"]["since"] == 2021
end

@testset "to_metagraph: edges auto-create dangling vertices" begin
    vertices = [Dict("id" => "person:alice", "name" => "Alice")]
    edges = [Dict("in" => "person:alice", "out" => "person:unknown")]

    g = SurrealDB.to_metagraph(vertices, edges)

    @test Graphs.nv(g.graph) == 2
    @test haskey(g, "person:unknown")
    @test g["person:unknown"]["id"] == "person:unknown"
end

@testset "to_metagraph: edge metadata excludes in/out" begin
    vertices = [
        Dict("id" => "a:1"), Dict("id" => "a:2"),
    ]
    edges = [Dict("in" => "a:1", "out" => "a:2", "weight" => 0.5, "kind" => "follows")]

    g = SurrealDB.to_metagraph(vertices, edges)

    edge_data = g["a:1", "a:2"]
    @test edge_data["weight"] == 0.5
    @test edge_data["kind"] == "follows"
    @test !haskey(edge_data, "in")
    @test !haskey(edge_data, "out")
end

@testset "to_metagraph: custom label/in/out fields" begin
    vertices = [Dict("uid" => "x:1"), Dict("uid" => "x:2")]
    edges = [Dict("from" => "x:1", "to" => "x:2", "tag" => "linked")]

    g = SurrealDB.to_metagraph(vertices, edges;
        label_field="uid", in_field="from", out_field="to")

    @test Graphs.nv(g.graph) == 2
    @test g["x:1", "x:2"]["tag"] == "linked"
end

@testset "to_metagraph: RecordID labels round-trip via string" begin
    rid1 = SurrealDB.RecordID("user", "alice")
    rid2 = SurrealDB.RecordID("user", "bob")
    vertices = [
        Dict("id" => rid1, "name" => "Alice"),
        Dict("id" => rid2, "name" => "Bob"),
    ]
    edges = [Dict("in" => rid1, "out" => rid2)]

    g = SurrealDB.to_metagraph(vertices, edges)

    # RecordID is stringified at graph-build time; labels are String.
    @test g[string(rid1)]["name"] == "Alice"
    @test Graphs.has_edge(g.graph, code_for(g, string(rid1)), code_for(g, string(rid2)))
end

@testset "to_metagraph: empty inputs produce empty graph" begin
    g = SurrealDB.to_metagraph(Dict[], Dict[])
    @test Graphs.nv(g.graph) == 0
    @test Graphs.ne(g.graph) == 0
end

@testset "to_metagraph: vertex missing label_field is skipped" begin
    vertices = [
        Dict("id" => "a:1", "name" => "ok"),
        Dict("name" => "no id field"),         # ← skipped
    ]
    g = SurrealDB.to_metagraph(vertices, Dict[])
    @test Graphs.nv(g.graph) == 1
    @test haskey(g, "a:1")
end

@testset "to_metagraph: graph supports Graphs.jl algorithms" begin
    # Chain graph a → b → c → d
    vertices = [Dict("id" => "n:$i") for i in 1:4]
    edges = [
        Dict("in" => "n:1", "out" => "n:2"),
        Dict("in" => "n:2", "out" => "n:3"),
        Dict("in" => "n:3", "out" => "n:4"),
    ]
    g = SurrealDB.to_metagraph(vertices, edges)

    # Reach n:4 from n:1 in 3 hops
    paths = Graphs.dijkstra_shortest_paths(g.graph, code_for(g, "n:1"))
    @test paths.dists[code_for(g, "n:4")] == 3.0
end
