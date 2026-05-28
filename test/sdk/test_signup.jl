# signup! coverage — RECORD-scope access registration.
#
# Defines an ACCESS with TYPE RECORD + SIGNUP clause, signs a new user up
# via the SDK, verifies the JWT comes back and the client's token state
# is populated. Mirrors test_jwt_expiry.jl's DEFINE ACCESS pattern.
#
# Server-gated. Skips on v2 only if ACCESS-RECORD isn't supported (rare —
# both v2 and v3 support it; the SIGNUP clause syntax matches).

using SurrealDB

@testset "signup! against RECORD-scope access" begin
    admin = SurrealDB.connect(TEST_URL; ns=TEST_NS, db=TEST_DB,
        auth=SurrealDB.RootAuth("root", "root"))
    try
        try; SurrealDB.query(admin, "REMOVE ACCESS sig_test ON DATABASE"); catch; end
        try; SurrealDB.query(admin, "REMOVE TABLE IF EXISTS sig_user"); catch; end
        SurrealDB.query(admin, "DEFINE TABLE sig_user")
        SurrealDB.query(admin, """
            DEFINE ACCESS sig_test ON DATABASE TYPE RECORD
                SIGNUP (CREATE sig_user CONTENT { name: \$user, pass: crypto::argon2::generate(\$pass) })
                SIGNIN (SELECT * FROM sig_user WHERE name = \$user AND crypto::argon2::compare(pass, \$pass))
                DURATION FOR SESSION 1h
        """)

        scoped = SurrealDB.connect(TEST_URL; ns=TEST_NS, db=TEST_DB)
        try
            token = SurrealDB.signup!(scoped,
                SurrealDB.ScopedAuth(TEST_NS, TEST_DB, "sig_test", "alice", "secret"))
            @test token isa String
            @test startswith(token, "eyJ")           # JWT header prefix
            @test scoped.token == token              # client state updated

            # Sanity: signing in with the same credentials works (cycle: signup → signin)
            SurrealDB.close!(scoped)
            scoped2 = SurrealDB.connect(TEST_URL; ns=TEST_NS, db=TEST_DB,
                auth=SurrealDB.ScopedAuth(TEST_NS, TEST_DB, "sig_test", "alice", "secret"))
            try
                @test scoped2.token isa String
            finally
                SurrealDB.close!(scoped2)
            end
        finally
            try; SurrealDB.close!(scoped); catch; end
        end
    finally
        try; SurrealDB.query(admin, "REMOVE ACCESS sig_test ON DATABASE"); catch; end
        try; SurrealDB.query(admin, "REMOVE TABLE IF EXISTS sig_user"); catch; end
        SurrealDB.close!(admin)
    end
end
