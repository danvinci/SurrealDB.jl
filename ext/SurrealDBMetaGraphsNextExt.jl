module SurrealDBMetaGraphsNextExt

# Pkg extension: bridges SurrealDB query results into MetaGraphsNext.MetaGraph.
# Loaded automatically by Julia 1.9+ when both `MetaGraphsNext` and `Graphs`
# are present in the user's environment alongside `SurrealDB`.
#
# Design boundary (per Phase 1 audit decision): NO auto-coerce. Users invoke
# `to_metagraph` explicitly with bounded queries. SurrealDB's whole point is
# that the graph stays on disk; pulling it into Julia memory is a per-task
# decision, not a default.

using SurrealDB
using MetaGraphsNext
using Graphs

# --- Helpers ---

function _row_id_string(row::AbstractDict, field::AbstractString)
    v = get(row, field, nothing)
    v === nothing && return nothing
    if v isa SurrealDB.RecordID
        return string(v)
    end
    return string(v)
end

function _new_metagraph()
    return MetaGraphsNext.MetaGraph(
        Graphs.DiGraph();
        label_type = String,
        vertex_data_type = Dict{String, Any},
        edge_data_type = Dict{String, Any},
    )
end

function _add_vertex_row!(g, row::AbstractDict; label_field::AbstractString = "id")
    label = _row_id_string(row, label_field)
    label === nothing && return false
    g[label] = Dict{String, Any}(string(k) => v for (k, v) in row)
    return true
end

function _add_edge_row!(g, row::AbstractDict;
                       in_field::AbstractString = "in",
                       out_field::AbstractString = "out")
    src = _row_id_string(row, in_field)
    dst = _row_id_string(row, out_field)
    (src === nothing || dst === nothing) && return false
    # Auto-create dangling vertices so callers don't need to pre-seed both
    # endpoints. Edge metadata gets the row minus in/out duplicate fields.
    if !haskey(g, src)
        g[src] = Dict{String, Any}("id" => src)
    end
    if !haskey(g, dst)
        g[dst] = Dict{String, Any}("id" => dst)
    end
    edge_data = Dict{String, Any}(string(k) => v for (k, v) in row
                                  if string(k) != in_field && string(k) != out_field)
    g[src, dst] = edge_data
    return true
end

# --- Public API (extension method bodies for SurrealDB stub functions) ---

"""
    to_metagraph(vertices, edges; label_field="id", in_field="in", out_field="out")

Materialize a `MetaGraphsNext.MetaGraph{DiGraph}` from pre-fetched vertex and
edge rows. `vertices` and `edges` are each iterables of `AbstractDict`
(typically `Vector{Dict{String,Any}}` from a [`SurrealDB.query`](@ref) call,
or rows of a [`SurrealDB.QueryResultTable`](@ref)).

Vertex labels are taken from `label_field` (default `"id"`), which should
contain a [`SurrealDB.RecordID`](@ref) or a `"table:id"` string. Edges are
keyed by `(in, out)` record-id strings; remaining fields become edge
metadata.

# Examples
```julia
using SurrealDB, MetaGraphsNext, Graphs
db = SurrealDB.connect("ws://localhost:8000")
SurrealDB.use!(db, "test", "test")

people = SurrealDB.query(db, "SELECT * FROM person")
edges  = SurrealDB.query(db, "SELECT * FROM knows")
g = SurrealDB.to_metagraph(people[1], edges[1])

# Now use any Graphs.jl algorithm
println(Graphs.dijkstra_shortest_paths(g.graph, code_for(g, "person:tobie")))
```
"""
function SurrealDB.to_metagraph(vertices, edges;
                                label_field::AbstractString = "id",
                                in_field::AbstractString = "in",
                                out_field::AbstractString = "out")
    g = _new_metagraph()
    for v in vertices
        v isa AbstractDict && _add_vertex_row!(g, v; label_field=label_field)
    end
    for e in edges
        e isa AbstractDict && _add_edge_row!(g, e; in_field=in_field, out_field=out_field)
    end
    return g
end

"""
    to_metagraph(client::SurrealClient, vertices_query::String, edges_query::String;
                 label_field="id", in_field="in", out_field="out", vars=Dict{String,Any}())

Convenience: run the two queries against `client`, flatten single-statement
results to row vectors, then materialize a MetaGraph. Vars are passed to both
queries.

# Examples
```julia
g = SurrealDB.to_metagraph(db,
        "SELECT * FROM person",
        "SELECT *, in.id AS in, out.id AS out FROM knows")
```
"""
function SurrealDB.to_metagraph(client::SurrealDB.SurrealClient,
                                vertices_query::AbstractString,
                                edges_query::AbstractString;
                                label_field::AbstractString = "id",
                                in_field::AbstractString = "in",
                                out_field::AbstractString = "out",
                                vars=Dict{String, Any}())
    vrows = _flatten_one(SurrealDB.query(client, String(vertices_query); vars=vars))
    erows = _flatten_one(SurrealDB.query(client, String(edges_query); vars=vars))
    return SurrealDB.to_metagraph(vrows, erows;
                                  label_field=label_field,
                                  in_field=in_field, out_field=out_field)
end

# Flatten a `query()` result to a single Vector of row Dicts. Handles the
# remote (Vector{Vector{Dict}}) and embedded (Vector{Dict}) shapes.
function _flatten_one(results)
    rows = Dict{String, Any}[]
    if isempty(results)
        return rows
    end
    if all(r -> r isa AbstractVector, results)
        for stmt in results, row in stmt
            row isa AbstractDict && push!(rows, Dict{String, Any}(row))
        end
    elseif all(r -> r isa AbstractDict, results)
        for row in results
            push!(rows, Dict{String, Any}(row))
        end
    else
        for r in results
            if r isa AbstractDict
                push!(rows, Dict{String, Any}(r))
            elseif r isa AbstractVector
                for row in r
                    row isa AbstractDict && push!(rows, Dict{String, Any}(row))
                end
            end
        end
    end
    return rows
end

end # module SurrealDBMetaGraphsNextExt
