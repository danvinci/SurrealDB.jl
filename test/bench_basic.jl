# Basic benchmarks for SurrealDB.jl
# Compare against Go SDK baseline (target: within 2x)
#
# Usage: SURREALDB_URL=ws://localhost:8000 julia --project=. test/bench_basic.jl

using SurrealDB
using Printf

const TEST_URL = get(ENV, "SURREALDB_URL", "ws://localhost:8000")
const ITERATIONS = 1000
const WARMUP = 10

function bench_select_one(client)
    t = @elapsed for _ in 1:ITERATIONS
        SurrealDB.query(client, "SELECT * FROM 1")
    end
    return t / ITERATIONS * 1000  # ms per iteration
end

function bench_create_select(client)
    t = @elapsed for i in 1:ITERATIONS
        rid = "bench:bs$i"
        SurrealDB.create(client, rid, Dict("val" => i))
        SurrealDB.select(client, rid)
    end
    return t / ITERATIONS * 1000  # ms per iteration
end

function bench_select_table(client)
    t = @elapsed for _ in 1:ITERATIONS
        SurrealDB.select(client, "bench")
    end
    return t / ITERATIONS * 1000  # ms per iteration
end

function run()
    println("SurrealDB.jl Benchmark")
    println("="^50)
    println("URL: $TEST_URL")
    println("Iterations: $ITERATIONS (warmup: $WARMUP)")
    println()

    client = SurrealDB.connect(TEST_URL)
    SurrealDB.use!(client, "test", "test")
    SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))

    # Setup
    SurrealDB.query(client, "DEFINE TABLE bench TYPE ANY SCHEMALESS")
    for i in 1:100
        SurrealDB.create(client, "bench:pre$i", Dict("val" => i))
    end

    # Warmup
    for _ in 1:WARMUP
        SurrealDB.query(client, "SELECT * FROM 1")
    end

    # Benchmark 1: SELECT * FROM 1
    t = bench_select_one(client)
    @printf "SELECT * FROM 1:    %.3f ms/op  (%d ops in %.2fs)\n" t ITERATIONS t*ITERATIONS/1000

    # Benchmark 2: CREATE + SELECT roundtrip
    t = bench_create_select(client)
    @printf "CREATE + SELECT:    %.3f ms/op  (%d ops in %.2fs)\n" t ITERATIONS t*ITERATIONS/1000

    # Benchmark 3: SELECT table
    t = bench_select_table(client)
    @printf "SELECT table:       %.3f ms/op  (%d ops in %.2fs)\n" t ITERATIONS t*ITERATIONS/1000

    # Cleanup
    SurrealDB.query(client, "DELETE FROM bench")
    SurrealDB.close!(client)

    println()
    println("Go SDK reference (single-op, localhost):")
    println("  SELECT * FROM 1:    ~1.5 ms/op")
    println("  CREATE + SELECT:    ~3.0 ms/op")
    println("  SELECT table:       ~2.0 ms/op")
    println("Target: within 2x of Go SDK")
end

run()
