# Regression pin on the embedded FFI struct ABI. These mirror Rust #[repr(C)]
# types in libsurrealdb_c. The live library validates the layout via the
# embedded round-trip tests, but those only run when the dylib is present.
# This pins the layout statically so a field reorder / type change fails loudly
# here (even in the unit-only leg) instead of segfaulting once the lib loads.
# On failure, re-verify the struct against the surrealdb.c header before
# touching the expected value.

const L = SurrealDB.LibSurreal

@testset "FFI struct layout" begin
    P = sizeof(Ptr{Cvoid})   # pointer width
    I = sizeof(Cint)

    @testset "SrCredentials" begin
        @test sizeof(L.SrCredentials) == 2P
        @test fieldoffset(L.SrCredentials, 1) == 0   # username
        @test fieldoffset(L.SrCredentials, 2) == P   # password
    end

    @testset "SrCredentialsAccess" begin
        @test sizeof(L.SrCredentialsAccess) == 3P
        @test fieldoffset(L.SrCredentialsAccess, 1) == 0    # namespace_
        @test fieldoffset(L.SrCredentialsAccess, 2) == P    # database
        @test fieldoffset(L.SrCredentialsAccess, 3) == 2P   # access
    end

    @testset "SrObject" begin
        @test sizeof(L.SrObject) == P
        @test fieldoffset(L.SrObject, 1) == 0   # inner
    end

    # SrArrRes hand-rolls _pad1/_pad2 to match the C layout. These offsets are
    # load-bearing: ok_len@8, err_code@16, err_msg@24, total 32. The array-result
    # parse path reads at these offsets.
    @testset "SrArrRes" begin
        @test sizeof(L.SrArrRes) == 2P + 4I
        @test fieldoffset(L.SrArrRes, 1) == 0        # ok_arr
        @test fieldoffset(L.SrArrRes, 2) == P        # ok_len   @ 8
        @test fieldoffset(L.SrArrRes, 4) == P + 2I   # err_code @ 16
        @test fieldoffset(L.SrArrRes, 6) == 2P + 2I  # err_msg  @ 24
    end
end
