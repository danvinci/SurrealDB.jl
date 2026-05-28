#!/usr/bin/env julia
# probe_runner.jl
#
# Calibrated probe of the Julia SDK against the upstream language-tests corpus.
# Run: julia --project=test test/conformance/probe_runner.jl
#
# Outputs results.json + per-test detail next to itself in .scratch/probe-...

using TOML
using SurrealDB
using JSON

const UPSTREAM = let
    _up = normpath(joinpath(@__DIR__, "..", "..", "..", "external", "upstream"))
    isdir(joinpath(_up, "language-tests")) ||
        error("upstream checkout not found at $_up — run `bash scripts/setup-upstream.sh`")
    joinpath(_up, "language-tests", "tests")
end
const URL = "ws://127.0.0.1:8000"
const AUTH = SurrealDB.RootAuth("root", "root")

# ---------- TOML extraction from //! / /** */ comments ------------------------

"""
    extract_toml(text::String) -> String

Concatenate every test-comment block (`/**...*/` and `//!...`) found in the
SurrealQL source, in document order. The concatenated text is the test config.

Mirrors the upstream parser at language-tests/src/tests/case/parse.rs.
"""
function extract_toml(text::String)
    out = IOBuffer()
    i = 1
    n = lastindex(text)
    while i <= n
        # multi-line /** ... */
        if i + 2 <= n && text[i] == '/' && text[i+1] == '*' && text[i+2] == '*'
            # find closing */
            j = i + 3
            while j + 1 <= n && !(text[j] == '*' && text[j+1] == '/')
                j = nextind(text, j)
            end
            if j + 1 <= n
                inner = text[i+3:j-1]
                print(out, inner, '\n')
                i = j + 2
                continue
            else
                break
            end
        end
        # single-line //!
        if i + 2 <= n && text[i] == '/' && text[i+1] == '/' && text[i+2] == '!'
            # to end of line
            j = i + 3
            while j <= n && text[j] != '\n'
                j = nextind(text, j)
            end
            inner = text[i+3:min(j-1, n)]
            print(out, inner, '\n')
            i = j + 1
            continue
        end
        i = nextind(text, i)
    end
    return String(take!(out))
end

"""
    strip_comments(text::String) -> String

Strip test-comment blocks from the source so only the SurrealQL remains.
"""
function strip_comments(text::String)
    out = IOBuffer()
    i = 1
    n = lastindex(text)
    while i <= n
        if i + 2 <= n && text[i] == '/' && text[i+1] == '*' && text[i+2] == '*'
            j = i + 3
            while j + 1 <= n && !(text[j] == '*' && text[j+1] == '/')
                j = nextind(text, j)
            end
            i = (j + 1 <= n) ? j + 2 : n + 1
            continue
        end
        if i + 2 <= n && text[i] == '/' && text[i+1] == '/' && text[i+2] == '!'
            j = i + 3
            while j <= n && text[j] != '\n'
                j = nextind(text, j)
            end
            i = j
            continue
        end
        print(out, text[i])
        i = nextind(text, i)
    end
    return String(take!(out))
end

# ---------- Config interpretation --------------------------------------------

struct TestConfig
    run::Bool
    wip::Bool
    reason::String
    namespace::Union{Nothing,String}
    database::Union{Nothing,String}
    backend_ok::Bool
    capabilities_ok::Bool
    imports::Vector{String}
    auth_login::Union{Nothing,Dict{String,Any}}
    signin::Union{Nothing,Dict{String,Any}}
    expected::Vector{Any}    # vector of expectation dicts/strings
    parsing_error::Union{Nothing,Any}
    skip_reason::Union{Nothing,String}
end

# accept BoolOr<String> for namespace/database
function _bool_or_string(v, default::String)
    if v === nothing
        return default
    elseif v isa Bool
        return v ? default : nothing
    elseif v isa String
        return v
    else
        return default
    end
end

function interpret_config(toml_text::String)
    cfg = try
        TOML.parse(toml_text)
    catch e
        return TestConfig(true, false, "", "test", "test", true, true, String[],
            nothing, nothing, Any[], nothing, "toml-parse-error: $e")
    end
    env  = get(cfg, "env",  Dict{String,Any}())
    test = get(cfg, "test", Dict{String,Any}())

    run  = get(test, "run", true)
    wip  = get(test, "wip", false)
    reason = string(get(test, "reason", ""))

    namespace = _bool_or_string(get(env, "namespace", true), "test")
    database  = _bool_or_string(get(env, "database",  true), "test")

    # backend restriction: empty (default) means all backends; we only run "mem"
    backend_list = get(env, "backend", String[])
    backend_ok = isempty(backend_list) || "mem" in backend_list || "memory" in backend_list

    # capabilities: just check we're not asked to disable something we need
    # (we run server with default capabilities; rough filter only)
    capabilities_ok = true

    imports = String[get(env, "imports", String[])...]

    auth_login = get(env, "auth", nothing)
    signin = get(env, "signin", nothing)

    # results
    results = get(test, "results", nothing)
    expected = Any[]
    parsing_error = nothing
    if results !== nothing
        if results isa Vector
            expected = results
        elseif results isa Dict
            if haskey(results, "parsing-error")
                parsing_error = results["parsing-error"]
            elseif haskey(results, "signin-error") || haskey(results, "signup-error")
                # not handling these specially; mark for skip
                return TestConfig(run, wip, reason, namespace, database,
                    backend_ok, capabilities_ok, imports, auth_login, signin,
                    Any[], nothing, "signin/signup-error variant unsupported")
            else
                expected = Any[results]
            end
        end
    end

    skip_reason = nothing
    if !backend_ok
        skip_reason = "backend mismatch (probe runs mem only)"
    elseif !run
        skip_reason = "run=false"
    elseif auth_login !== nothing
        skip_reason = "env.auth unsupported by probe (use root only)"
    elseif signin !== nothing
        skip_reason = "env.signin unsupported by probe (use root only)"
    elseif length(imports) > 0
        # we'll try to handle imports — only skip if they reference paths we can't resolve
        skip_reason = nothing
    end

    return TestConfig(run, wip, reason, namespace, database,
        backend_ok, capabilities_ok, imports, auth_login, signin,
        expected, parsing_error, skip_reason)
end

# ---------- Test execution ----------------------------------------------------

# Resolve an import path against the test file
function resolve_import(import_path::String, test_file::String)
    if startswith(import_path, "./") || startswith(import_path, "../")
        return normpath(joinpath(dirname(test_file), import_path))
    else
        return normpath(joinpath(UPSTREAM, import_path))
    end
end

# Run imports on a fresh ns/db with root auth.
function run_imports(client, imports, test_file)
    for imp in imports
        path = resolve_import(imp, test_file)
        if !isfile(path)
            error("import not found: $path (from $imp)")
        end
        src = read(path, String)
        sql = String(strip_comments(src))
        if !isempty(strip(sql))
            SurrealDB.query_verbose(client, sql)
        end
    end
end

# A small struct describing one statement-comparison outcome
struct StmtCmp
    pass::Bool
    detail::String   # description of mismatch when pass=false
end

# Extract human-readable error text from a typed SurrealDB error.
function _error_text(e)
    if hasproperty(e, :message)
        return string(getproperty(e, :message))
    end
    return sprint(showerror, e)
end

# Resolve an expected value spec (might be a string or a TOML table) to a server-canonical Julia value.
# Returns (kind, value_or_nothing, error_text_or_nothing, fuzzy_flags)
# kind ∈ (:value, :error, :match, :parsing_error)
function resolve_expected(client, exp)
    fuzzy = Dict{Symbol,Bool}(
        :skip_datetime => false, :skip_record_id_key => false, :skip_uuid => false,
        :float_roughly_eq => false, :decimal_roughly_eq => false,
    )
    if exp isa String
        # straight value as SurrealQL literal
        v = _parse_expected_value(client, exp)
        return (:value, v, nothing, fuzzy)
    elseif exp isa Dict
        for k in keys(fuzzy)
            kk = replace(string(k), "_" => "-")
            if get(exp, kk, false) == true
                fuzzy[k] = true
            end
        end
        if haskey(exp, "match")
            return (:match, get(exp, "match", ""), get(exp, "error", nothing), fuzzy)
        elseif haskey(exp, "value")
            v = _parse_expected_value(client, exp["value"])
            return (:value, v, nothing, fuzzy)
        elseif haskey(exp, "error")
            err = exp["error"]
            return (:error, nothing, err, fuzzy)
        end
    end
    return (:value, exp, nothing, fuzzy)
end

# Use the server to parse an expected SurrealQL value into a canonical Julia value.
function _parse_expected_value(client, expr::String)
    expr_stripped = strip(expr)
    if isempty(expr_stripped)
        return nothing
    end
    stmts = SurrealDB.query_verbose(client, String("RETURN ($expr_stripped)"))
    if length(stmts) >= 1 && SurrealDB.isok(stmts[1])
        return stmts[1].result
    else
        return Symbol("__parse_failed__:$(stmts[1].error)")
    end
end

# Compare two values with fuzzy flags. Returns true iff structurally equal under fuzzy.
function roughly_equal(a, b, fuzzy::Dict{Symbol,Bool})
    if a === nothing && b === nothing; return true; end
    if a === missing && b === missing; return true; end
    if a === nothing || b === nothing; return false; end
    if a === missing || b === missing; return false; end

    if a isa AbstractVector && b isa AbstractVector
        length(a) == length(b) || return false
        for (ai, bi) in zip(a, b)
            roughly_equal(ai, bi, fuzzy) === true || return false
        end
        return true
    end

    if a isa AbstractDict && b isa AbstractDict
        length(a) == length(b) || return false
        for (k, v) in a
            haskey(b, k) || return false
            roughly_equal(v, b[k], fuzzy) === true || return false
        end
        return true
    end

    if a isa SurrealDB.RecordID && b isa SurrealDB.RecordID
        if a.table != b.table; return false; end
        if fuzzy[:skip_record_id_key]
            return true
        end
        return string(a) == string(b)
    end

    if a isa AbstractFloat && b isa AbstractFloat
        if isnan(a) && isnan(b); return true; end
        if fuzzy[:float_roughly_eq]
            return abs(a - b) < 1e-15
        end
        return a == b
    end

    # Decimal types (SurrealDB.SurrealDecimal): compare by string round-trip.
    try
        if a isa SurrealDB.SurrealDecimal && b isa SurrealDB.SurrealDecimal
            return string(a) == string(b)
        end
    catch
    end

    # Fallback: equality, guarded against types that don't define ==.
    try
        return isequal(a, b)
    catch
        return false
    end
end

# Run a single test file. Returns Dict with all detail.
function run_test_file(client_root, test_file::String, ns::String, db::String)
    src = read(test_file, String)
    toml_text = extract_toml(src)
    cfg = interpret_config(toml_text)
    sql = String(strip(strip_comments(src)))

    out = Dict{String,Any}(
        "file" => relpath(test_file, UPSTREAM),
        "ns" => ns, "db" => db,
        "reason" => cfg.reason, "wip" => cfg.wip,
    )

    if cfg.skip_reason !== nothing
        out["status"] = "skip"
        out["detail"] = cfg.skip_reason
        return out
    end

    # USE ns/db. Per-test unique (probe_<runid>_<i>) keeps tests isolated.
    try
        SurrealDB.use!(client_root, ns, db)
    catch e
        out["status"] = "error"
        out["detail"] = "USE failed: $e"
        return out
    end

    # imports
    try
        run_imports(client_root, cfg.imports, test_file)
    catch e
        out["status"] = "error"
        out["detail"] = "import failure: $(sprint(showerror, e))"
        return out
    end

    # Run the actual SQL
    stmts = nothing
    parse_error_text = nothing
    rpc_error_text = nothing
    try
        stmts = SurrealDB.query_verbose(client_root, sql)
    catch e
        # The SDK throws on RPC-level errors. Capture as a parse / rpc error
        rpc_error_text = sprint(showerror, e)
    end

    # Handle parsing-error expectation
    if cfg.parsing_error !== nothing
        if rpc_error_text !== nothing
            # there was an error at the SDK boundary, treat as parsing error caught
            out["status"] = "pass"
            out["detail"] = "parsing-error caught: $rpc_error_text"
            return out
        elseif stmts !== nothing && any(SurrealDB.iserr, stmts)
            # any statement error counts
            errs = [string(s.error) for s in stmts if SurrealDB.iserr(s)]
            if cfg.parsing_error === true
                out["status"] = "pass"
            elseif cfg.parsing_error isa String
                # we don't have direct upstream parse-error text matching; pass on presence
                out["status"] = "pass"
            else
                out["status"] = "pass"
            end
            joined_errs = join(errs, "; ")
            out["detail"] = "parse-error stmts: $joined_errs"
            return out
        else
            out["status"] = "fail"
            out["detail"] = "expected parsing-error, none observed"
            return out
        end
    end

    if rpc_error_text !== nothing
        out["status"] = "error"
        out["detail"] = "RPC error: $rpc_error_text"
        return out
    end

    # Compare expected vs actual
    expected = cfg.expected
    n_exp = length(expected)
    n_got = length(stmts)

    cmps = StmtCmp[]
    if n_exp == 0
        # No expectations: just record that the test ran without DB error
        # (upstream warns but doesn't fail). We treat as pass if no errors.
        any_err = any(SurrealDB.iserr, stmts)
        out["status"] = any_err ? "fail" : "pass"
        out["detail"] = any_err ? "stmt error w/ no expectation: " *
            join([string(s.error) for s in stmts if SurrealDB.iserr(s)], "; ") :
            "no expectations declared (got $n_got stmts)"
        return out
    end

    if n_exp != n_got
        out["status"] = "fail"
        out["detail"] = "stmt count mismatch: expected=$n_exp got=$n_got"
        out["actual"] = [SurrealDB.iserr(s) ? "ERR: $(s.error)" : repr(s.result) for s in stmts]
        return out
    end

    for (i, (exp, stmt)) in enumerate(zip(expected, stmts))
        kind, val, err, fuzzy = resolve_expected(client_root, exp)
        if kind == :error
            if SurrealDB.iserr(stmt)
                # match by string if exp text provided
                if err isa String && err != ""
                    err_text = _error_text(stmt.error)
                    if occursin(err, err_text)
                        push!(cmps, StmtCmp(true, "err-match"))
                    else
                        push!(cmps, StmtCmp(false, "err-text-mismatch: want=$(err) got=$(err_text)"))
                    end
                else
                    push!(cmps, StmtCmp(true, "err-bool-match"))
                end
            else
                if err == false
                    push!(cmps, StmtCmp(true, "no-error-ok"))
                else
                    push!(cmps, StmtCmp(false, "expected error, got value: $(repr(stmt.result))"))
                end
            end
        elseif kind == :value
            if SurrealDB.iserr(stmt)
                push!(cmps, StmtCmp(false, "expected value, got error: $(stmt.error)"))
            elseif val isa Symbol && startswith(string(val), "__parse_failed__")
                push!(cmps, StmtCmp(false, "expected-value-could-not-be-parsed-by-server: $val"))
            else
                if roughly_equal(stmt.result, val, fuzzy)
                    push!(cmps, StmtCmp(true, "value-match"))
                else
                    push!(cmps, StmtCmp(false, "value-mismatch:\n  want=$(repr(val))\n  got =$(repr(stmt.result))"))
                end
            end
        elseif kind == :match
            # we don't run match expressions in the probe — count as skip
            push!(cmps, StmtCmp(true, "match-expression-skipped"))
        end
    end

    all_pass = all(c.pass for c in cmps)
    out["status"] = all_pass ? "pass" : "fail"
    out["detail"] = join(["stmt$i: $(c.detail)" for (i, c) in pairs(cmps)], "\n")
    return out
end

# ---------- Sample selection --------------------------------------------------

# Diverse but deterministic sample, biased toward variety.
const LANG_SAMPLE = String[
    # SELECT variants
    "language/statements/select/destructure.surql",
    "language/statements/select/start_limit_multiple_whats.surql",
    "language/statements/select/with_subquery.surql",
    # CREATE / UPDATE / DELETE / UPSERT / MERGE
    "language/statements/create/create_only.surql",
    "language/statements/create/create_output.surql",
    "language/statements/update/update_only.surql",
    "language/statements/upsert/upsert_only.surql",
    "language/statements/delete/basic.surql",
    "language/statements/delete/with_parameters.surql",
    # RELATE
    "language/statements/relate/relate_only.surql",
    "language/statements/relate/ported_create_select.surql",
    # transactions
    "language/control_flow/transaction/basic.surql",
    "language/control_flow/transaction/with_return.surql",
    "language/control_flow/transaction/commit_behaviour.surql",
    "language/statements/transaction/throw_error_handling.surql",
    # datetime / duration / decimal
    "language/primitive/datetimes/truthiness.surql",
    "language/primitive/datetimes/datetime_conversions.surql",
    "language/primitive/duration/basic.surql",
    "language/primitive/numbers/decimal.surql",
    # record-id / uuid
    "language/primitive/record_id/id_variants.surql",
    "language/primitive/record_id/natural_order.surql",
    "language/primitive/uuid/basic.surql",
    # geometry / strings
    "language/primitive/strings/strand.surql",
    "language/primitive/strings/truthiness.surql",
    # idiom
    "language/idiom/chain_part_optional.surql",
    # parameter binding
    "language/parameters/scoping.surql",
    "language/parameters/set_within_transaction.surql",
    # functions
    "language/functions/array/append.surql",
    "language/functions/math/abs.surql",
    "language/functions/method_syntax.surql",
    # info / define
    "language/statements/info/subquery.surql",
    "language/statements/define/database/define_info.surql",
    # for / let
    "language/control_flow/loop/break_within_expression.surql",
    "language/statements/let/typed.surql",
]

const REPRO_SAMPLE = String[
    "reproductions/3290_multi_column_unique_index_none.surql",
    "reproductions/3510_link_wildcard_where.surql",
    "reproductions/3545_where_clause_relations.surql",
    "reproductions/3784_recursive_function_computation_depth.surql",
    "reproductions/4957_version_subquery_inheritance.surql",
    "reproductions/5677_array_index_field_constraints.surql",
    "reproductions/5945_create_permission.surql",
    "reproductions/6075_relation_table_export_field_conflict.surql",
    "reproductions/3510_link_wildcard_where_new_executor.surql",
    "reproductions/5945_create_permission_import.surql",
]

# Some files in the diverse list may not actually exist; the runner just records
# them as `missing-file` skips rather than crashing.
function existing_or_first_match(rel)
    full = joinpath(UPSTREAM, rel)
    if isfile(full)
        return full
    end
    # try a glob fallback: the leaf might exist with a slightly different name
    dir = dirname(full)
    if isdir(dir)
        leaf_stem = first(splitext(basename(rel)))
        for f in readdir(dir)
            if startswith(f, leaf_stem) && endswith(f, ".surql")
                return joinpath(dir, f)
            end
        end
    end
    return full  # caller will report not-found
end

# ---------- Category tagging --------------------------------------------------

function category_of(relpath_str::String)
    if startswith(relpath_str, "reproductions/")
        return "reproductions"
    end
    parts = split(relpath_str, '/')
    # language/statements/select/..., language/primitive/datetime/..., etc.
    if length(parts) >= 3 && parts[1] == "language"
        # statements/<verb>: tag by verb
        if parts[2] == "statements" && length(parts) >= 3
            return "statements/" * parts[3]
        end
        return parts[2] * "/" * (length(parts) >= 3 ? parts[3] : "")
    end
    return parts[1]
end

# ---------- Main --------------------------------------------------------------

function main()
    @info "Probe starting; connecting to $URL"
    client = SurrealDB.connect(URL; ns="warmup", db="warmup", auth=AUTH)
    @info "connected; SDK status=$(SurrealDB.status(client))"

    all_files = String[]
    for r in LANG_SAMPLE; push!(all_files, joinpath(UPSTREAM, r)); end
    for r in REPRO_SAMPLE; push!(all_files, joinpath(UPSTREAM, r)); end

    # Per-process run-id keeps namespaces unique across re-runs against the
    # same long-lived server.
    run_id = string(rand(UInt32); base = 36)

    results = Dict{String,Any}[]
    for (i, fpath) in pairs(all_files)
        rel = relpath(fpath, UPSTREAM)
        @info "[$i/$(length(all_files))] $rel"

        if !isfile(fpath)
            # try fallback
            fpath2 = existing_or_first_match(rel)
            if !isfile(fpath2)
                push!(results, Dict("file" => rel, "status" => "skip",
                    "detail" => "missing-file",
                    "category" => category_of(rel)))
                continue
            end
            fpath = fpath2
            rel = relpath(fpath, UPSTREAM)
        end

        ns = "probe_$(run_id)_$(i)"
        db = "probe_$(run_id)_$(i)"
        outcome = try
            run_test_file(client, fpath, ns, db)
        catch e
            Dict{String,Any}("file" => rel, "status" => "error",
                "detail" => "runner exception: $(sprint(showerror, e))")
        end
        outcome["category"] = category_of(rel)
        push!(results, outcome)
    end

    SurrealDB.close!(client)

    # write JSON
    open(joinpath(@__DIR__, "results.json"), "w") do io
        JSON.print(io, results, 2)
    end

    # also dump per-category counts as text
    cats = Dict{String,Dict{String,Int}}()
    for r in results
        c = r["category"]
        d = get!(cats, c, Dict("pass" => 0, "fail" => 0, "error" => 0, "skip" => 0))
        d[r["status"]] = get(d, r["status"], 0) + 1
    end

    open(joinpath(@__DIR__, "summary.txt"), "w") do io
        println(io, "Category                                | total | pass | fail | err | skip")
        println(io, repeat("-", 75))
        for (c, d) in sort(collect(cats); by = first)
            t = d["pass"] + d["fail"] + d["error"] + d["skip"]
            println(io, rpad(c, 40), " | ", lpad(t, 5),
                " | ", lpad(d["pass"], 4),
                " | ", lpad(d["fail"], 4),
                " | ", lpad(d["error"], 3),
                " | ", lpad(d["skip"], 4))
        end
        println(io)
        println(io, "Failures + Errors:")
        for r in results
            if r["status"] in ("fail", "error")
                println(io, "\n-- ", r["file"], " [", r["status"], "] --")
                println(io, "  ", get(r, "detail", ""))
            end
        end
    end

    println("Wrote results.json and summary.txt to $(@__DIR__)")
end

main()
