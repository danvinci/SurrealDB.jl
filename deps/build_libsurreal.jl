# Build libsurreal shared library from surrealdb/surrealdb.c
#
# Usage:
#   julia deps/build_libsurreal.jl
#   julia deps/build_libsurreal.jl /path/to/output/lib
#
# Requires: Rust toolchain (cargo), git

const REPO_URL = "https://github.com/surrealdb/surrealdb.c.git"
# Pin: surrealdb.c HEAD as of 2026-05-04 (the build that produced the dylib
# checked in at the project root). `sr_value_t` stride is 48 bytes for this
# build; the runtime self-test in `LibSurreal._self_test_layout()` will catch
# layout drift if a newer build changes things.
# Override via SURREALDB_C_REF env var to build a different revision.
const REPO_REF = get(ENV, "SURREALDB_C_REF", "main")

function build_libsurreal(output_dir::String = abspath(dirname(@__FILE__), ".."))
    build_dir = mktempdir(; cleanup = true)
    repo_dir = joinpath(build_dir, "surrealdb.c")

    @info "Cloning surrealdb.c (shallow) ..."
    run(`git clone --depth 1 --branch $REPO_REF $REPO_URL $repo_dir`)

    @info "Building with cargo (this may take several minutes) ..."
    cd(repo_dir) do
        run(`cargo build --release`)
    end

    lib_name = if Sys.islinux()
        "libsurrealdb_c.so"
    elseif Sys.isapple()
        "libsurrealdb_c.dylib"
    elseif Sys.iswindows()
        "surrealdb_c.dll"
    else
        error("Unsupported platform: $(Sys.KERNEL)")
    end

    src = joinpath(repo_dir, "target", "release", lib_name)
    dst = joinpath(output_dir, lib_name)

    if !isfile(src)
        error("Build failed: $src not found. Check cargo output above.")
    end

    cp(src, dst; force = true)
    @info "Built: $dst ($(filesize(dst) ÷ (1024 * 1024)) MB)"

    return dst
end

output_dir = length(ARGS) > 0 ? ARGS[1] : abspath(dirname(@__FILE__), "..")

if !isfile(joinpath(output_dir, "__init__.jl"))
    output_dir = joinpath(output_dir, "deps")
end
mkpath(output_dir)

build_libsurreal(output_dir)
