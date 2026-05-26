# HTTP transport layer — stateless RPC calls

function _rpc_call_http(client::SurrealClient{<:RemoteHTTPConnection}, method::String, params::Vector{Any};
                      session=nothing, txn=nothing)
    conn = client.connection
    # Lock scope covers id allocation + msg + headers prep. Throws inside
    # `_http_adapt_method` / `_wire_content_type` / `JSON.json` would leak
    # the lock permanently without the try/finally — see s13 audit.
    local rid::Int
    local url::String
    local msg::Dict
    local headers::Vector
    lock(conn.lock) do
        conn.request_id += 1
        rid = conn.request_id
        url = conn.http_base_url * "/rpc"

        # For HTTP, auto-prepend USE NS/DB since it is a stateless protocol
        ns = client.namespace
        db = client.database
        ns_db_prefix = (!isnothing(ns) && !isnothing(db)) ? "USE NS $ns DB $db;\n" : ""

        # Auto-convert CRUD methods to SurrealQL for HTTP (so USE NS/DB applies)
        effective_method, effective_params = _http_adapt_method(method, params, ns_db_prefix)

        msg = Dict("id" => rid, "method" => effective_method, "params" => effective_params)
        if !isnothing(session)
            msg["session"] = string(session)
        end
        if !isnothing(txn)
            msg["txn"] = string(txn)
        end
        content_type = _wire_content_type(conn)
        headers = ["Content-Type" => content_type, "Accept" => content_type]
        tok = client.token
        if !isnothing(tok)
            push!(headers, "Authorization" => "Bearer $tok")
        end
    end

    @debug "SurrealDB http RPC →" rid=rid method=effective_method wire=_wire(conn)
    # Mirror WS transport's rpc_timeout: HTTP.jl defaults readtimeout=0 (unbounded),
    # so a slow/hung server hangs the caller. `Inf` disables (HTTP.jl's 0 sentinel).
    read_to = isinf(conn.rpc_timeout) ? 0 : max(1, Int(ceil(conn.rpc_timeout)))
    resp = nothing  # JET noticed it could be undefined if HTTP.post throws
    try
        resp = HTTP.post(url, headers, _wire_encode(conn, msg); readtimeout=read_to, status_exception=false)
        # 406 Not Acceptable surfaces as a clear feature-unavailable signal
        # (server refused our `Accept`). No silent JSON fallback.
        if resp.status == 406
            throw(UnsupportedFeatureError(_wire(conn), :http))
        end
        if resp.status != 200
            throw(ConnectionError("HTTP $(resp.status): $(String(resp.body))"))
        end
        response = _wire_decode(conn, resp.body)
        @debug "SurrealDB http RPC ←" rid=rid status=resp.status has_error=(response isa AbstractDict && haskey(response, "error"))
        if response isa AbstractDict && haskey(response, "error")
            err = response["error"]
            if err isa AbstractDict
                throw(_parse_rpc_error(err))
            else
                throw(RPCError(-1, string(err)))
            end
        end
        return get(response, "result", nothing)
    catch e
        if e isa SurrealError
            rethrow()
        end
        throw(ConnectionError("HTTP request failed: $e", e))
    end
end

function _http_adapt_method(method::String, params::Vector{Any}, prefix::String)
    isempty(prefix) && return method, params

    if method == "query"
        sql = params[1]
        vars = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * sql, vars]
    elseif method == "select"
        what = string(params[1])
        return "query", Any[prefix * "SELECT * FROM $what", Dict{String, Any}()]
    elseif method == "create"
        what = string(params[1])
        data = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "CREATE $what CONTENT \$data", Dict("data" => data)]
    elseif method == "update"
        what = string(params[1])
        data = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "UPDATE $what MERGE \$data", Dict("data" => data)]
    elseif method == "delete"
        what = string(params[1])
        return "query", Any[prefix * "DELETE FROM $what", Dict{String, Any}()]
    elseif method == "insert"
        table = string(params[1])
        data = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "INSERT INTO $table \$data", Dict("data" => data)]
    elseif method == "upsert"
        what = string(params[1])
        data = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "UPSERT $what CONTENT \$data", Dict("data" => data)]
    elseif method == "merge"
        what = string(params[1])
        data = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "UPDATE $what MERGE \$data", Dict("data" => data)]
    elseif method == "relate"
        rel_in = string(params[1])
        relation = string(params[2])
        rel_out = string(params[3])
        data = length(params) > 3 ? params[4] : nothing
        data_json = !isnothing(data) ? " CONTENT \$data" : ""
        extra_vars = !isnothing(data) ? Dict("data" => data) : Dict{String, Any}()
        return "query", Any[prefix * "RELATE $rel_in->$relation->$rel_out$data_json", extra_vars]
    elseif method == "insert_relation"
        relation = string(params[1])
        payload = length(params) > 1 ? params[2] : Dict{String, Any}()
        return "query", Any[prefix * "INSERT INTO $relation \$data", Dict("data" => payload)]
    elseif method == "live"
        throw(UnsupportedFeatureError(:live, :http))
    elseif method == "run"
        # params = [fn_name, version, args]. Version is currently ignored —
        # the SurrealQL fn:: syntax doesn't expose a per-call version pin.
        # Args become positional variable bindings ($arg0, $arg1, ...) so
        # the function name is the only un-bound interpolation; validate it
        # to a strict identifier shape to block SQL-injection via fn_name.
        # Caller passes the full namespaced name (`"fn::adder"`); the SurrealQL
        # RETURN form takes it verbatim. Validate identifier shape (incl. `::`)
        # to block SQL-injection via fn_name; args bind as variables so their
        # values can't escape.
        fn_name = string(params[1])
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$", fn_name) ||
            throw(ArgumentError("invalid SurrealDB function name for HTTP rewrite: $fn_name"))
        args = length(params) > 2 ? params[3] : Any[]
        names = ["arg$(i-1)" for i in 1:length(args)]
        arg_list = join(("\$" * n for n in names), ", ")
        vars = Dict{String, Any}(zip(names, args))
        return "query", Any[prefix * "RETURN $fn_name($arg_list)", vars]
    elseif method == "info"
        # `info` is scoped to the selected namespace + database; passing it
        # through unprefixed returns root-level info instead of the database
        # the caller `use!`'d. Rewrite to a database-scoped INFO query.
        return "query", Any[prefix * "INFO FOR DB", Dict{String,Any}()]
    elseif method == "patch"
        # params = [what, patches::Vector{Dict{String,Any}}, diff::Bool]
        # SurrealQL: UPDATE <what> PATCH $patches [RETURN DIFF].
        what = string(params[1])
        patches = params[2]
        diff = length(params) > 2 ? (params[3] === true) : false
        return_clause = diff ? " RETURN DIFF" : ""
        return "query", Any[prefix * "UPDATE $what PATCH \$patches$return_clause",
                            Dict("patches" => patches)]
    else
        # Non-data methods (signin, use, info, version, etc.) pass through unchanged
        return method, params
    end
end
