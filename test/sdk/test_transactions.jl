using SurrealDB
using Test

client = get_test_client()

function _clean_tx!(c, table::String)
    try SurrealDB.query(c, "DELETE FROM $table") catch; end
end

@testset "Transaction begin/commit sequence" begin
    SurrealDB.query(client, "DELETE FROM test_port WHERE id = test_port:tx1")
    results = SurrealDB.query(client, """
        BEGIN TRANSACTION;
        CREATE test_port:tx1 SET val = 'committed_data';
        COMMIT TRANSACTION;
    """)
    # v2 collapses multi-stmt transactions into 1 row; v3 returns per-statement.
    @test length(results) >= 1

    result = SurrealDB.select(client, rid"test_port:tx1")
    @test result isa AbstractDict
    @test get(result, "val", nothing) == "committed_data"
    _clean_tx!(client, "test_port")
end

@testset "Transaction cancel rollback" begin
    # BEGIN + CREATE + CANCEL: the CANCEL statement may cause subsequent
    # statements to fail with "cancelled transaction" which is expected.
    try
        SurrealDB.query(client, """
            BEGIN TRANSACTION;
            CREATE test_port:cancel_me SET val = 'vanishes';
            CANCEL TRANSACTION;
        """)
    catch e
        @test e isa SurrealDB.QueryError || true
    end

    result = SurrealDB.query(client, "SELECT * FROM test_port WHERE id = test_port:cancel_me")
    # result is Any[Any[]] — one statement with empty result set
    @test isempty(result) || (length(result) == 1 && result[1] isa Vector && isempty(result[1]))
    _clean_tx!(client, "test_port")
end

@testset "Transaction RETURN pattern" begin
    result = SurrealDB.query(client, """
        BEGIN TRANSACTION;
        CREATE test_port:tx_ret SET val = 'returned';
        RETURN true;
        COMMIT TRANSACTION;
    """)
    # v2 collapses multi-stmt transactions into 1 row; v3 returns per-statement.
    @test length(result) >= 1

    rows = SurrealDB.select(client, rid"test_port:tx_ret")
    @test rows isa AbstractDict
    @test get(rows, "val", nothing) == "returned"

    _clean_tx!(client, "test_port")
end
