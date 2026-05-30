# Low-level ccall wrappers for libsurreal C API
# 1:1 mirror of surrealdb.h — internal module, not directly exported

module LibSurreal

using Libdl: Libdl
# Now nested 2 deep (SurrealDB > Embedded > LibSurreal); reach the parent
# package via 3 dots. Embedded re-imports EmbeddedFFIError from SurrealDB.
import ..Embedded: EmbeddedFFIError

# --- Library loading ---

const _lib = Ref{Ptr{Cvoid}}(C_NULL)

# Runtime getter — prevents precompilation from baking C_NULL into ccall library args
function _get_lib()
    p = _lib[]
    p == C_NULL && throw(EmbeddedFFIError("_get_lib", "libsurreal not loaded. Use SurrealDB.libsurreal_load!(\"path\") or connect via WebSocket/HTTP."))
    return p
end

# Resolve symbol at runtime via dlsym — avoids ccall compile-time library resolution
function _sym(name::Union{String, Symbol})
    ptr = Libdl.dlsym(_get_lib(), name)
    ptr == C_NULL && throw(EmbeddedFFIError("_sym", "Symbol not found: $name"))
    return ptr
end

_is_loaded() = _lib[] != C_NULL

function load!(path::String="")
    if isempty(path)
        path = get(ENV, "SURREALDB_LIB", "")
    end
    if isempty(path)
        throw(EmbeddedFFIError("load!", "libsurreal not loaded. Use SurrealDB.libsurreal_load!(\"path\") or set SURREALDB_LIB env var."))
    end
    _lib[] = Libdl.dlopen(path)
    # Reset cached probe so self-test runs fresh against the new library
    _SRVALUE_SIZE[] = Csize_t(0)
    _self_test_layout()
    return nothing
end

function ensure_loaded!()
    if _lib[] == C_NULL
        load!()
    end
    return nothing
end

function is_loaded()::Bool
    return _lib[] != C_NULL
end

# --- FFI struct types (C layout mirrors) ---

# sr_credentials { sr_string_t username; sr_string_t password; }
struct SrCredentials
    username::Cstring
    password::Cstring
end

# sr_credentials_access { sr_string_t namespace_; sr_string_t database; sr_string_t access; }
struct SrCredentialsAccess
    namespace_::Cstring
    database::Cstring
    access::Cstring
end

# sr_object_t { struct sr_opaque_object_internal_t *_0; }
struct SrObject
    inner::Ptr{Cvoid}
end

# sr_arr_res_t layout for safe cleanup
#   sr_array_t ok     { sr_value_t *arr; int len; }          → 8 + 4 + 4pad = 16
#   sr_SurrealError err { int code;      sr_string_t msg; }   → 4 + 4pad + 8 = 16
# Total: 32 bytes
struct SrArrRes
    ok_arr::Ptr{Cvoid}
    ok_len::Cint
    _pad1::Cint
    err_code::Cint
    _pad2::Cint
    err_msg::Cstring
end

# --- sr_value_t → Julia value conversion ---

# sr_id_t tag (matches sr_id_t_Tag)
const ID_NUMBER = Int32(0)
const ID_STRING = Int32(1)
const ID_ARRAY  = Int32(2)
const ID_OBJECT = Int32(3)

# Number tag (matches sr_number_t_Tag)
const NUM_INT     = Int32(0)
const NUM_FLOAT   = Int32(1)
const NUM_DECIMAL = Int32(2)

# Read a single sr_value_t at `p` and convert to Julia type
function _parse_sr_value(p::Ptr{Cvoid})::Any
    p == C_NULL && return nothing
    tag = unsafe_load(Ptr{Int32}(p))
    off = p + 8  # union data starts at offset 8

    if tag == C_VALUE_NONE;       return nothing
    elseif tag == C_VALUE_NULL;   return missing
    elseif tag == C_VALUE_BOOL;   return unsafe_load(Ptr{UInt8}(off)) != 0
    elseif tag == C_VALUE_NUMBER
        ntag = unsafe_load(Ptr{Int32}(off))
        if ntag == NUM_INT;       return unsafe_load(Ptr{Int64}(off + 8))
        elseif ntag == NUM_FLOAT; return unsafe_load(Ptr{Float64}(off + 8))
        else                      return _cstring_to_string(unsafe_load(Ptr{Cstring}(off + 8)))
        end
    elseif tag == C_VALUE_STRAND || tag == C_VALUE_DATETIME || tag == C_VALUE_DURATION
        return _cstring_to_string(unsafe_load(Ptr{Cstring}(off)))
    elseif tag == C_VALUE_UUID
        bytes = Vector{UInt8}(undef, 16)
        for i in 0:15; bytes[i+1] = unsafe_load(Ptr{UInt8}(off + i)); end
        return UUIDs.UUID(bytes)
    elseif tag == C_VALUE_ARRAY
        arr_ptr = unsafe_load(Ptr{Ptr{Cvoid}}(off))
        arr_ptr == C_NULL && return Any[]
        n = ccall(_sym("sr_array_len"), Cint, (Ptr{Cvoid},), arr_ptr)
        result = Any[]
        for i in 0:n-1
            elem = ccall(_sym("sr_array_get"), Ptr{Cvoid}, (Ptr{Cvoid}, Cint), arr_ptr, i)
            push!(result, _parse_sr_value(elem))
        end
        return result
    elseif tag == C_VALUE_OBJECT
        return _parse_sr_object(off)
    elseif tag == C_VALUE_THING
        table_ptr = unsafe_load(Ptr{Cstring}(off))
        table = table_ptr == C_NULL ? "?" : unsafe_string(table_ptr)
        id_ptr = off + 8
        idtag = unsafe_load(Ptr{Int32}(id_ptr))
        id_val = if idtag == ID_STRING
            _cstring_to_string(unsafe_load(Ptr{Cstring}(id_ptr + 8)))
        elseif idtag == ID_NUMBER
            unsafe_load(Ptr{Int64}(id_ptr + 8))
        else
            "?"
        end
        return string(table, ":", id_val)
    elseif tag == C_VALUE_BYTES || tag == C_GEOMETRY_OBJECT
        return nothing  # Not yet implemented
    else
        throw(EmbeddedFFIError("_parse_sr_value", "Unknown sr_value_t tag: $tag"))
    end
end

function _parse_sr_object(obj_ptr::Ptr{Cvoid})::Dict{String, Any}
    result = Dict{String, Any}()
    obj_ptr == C_NULL && return result

    keys_out = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
    n = ccall(_sym("sr_object_keys"), Cint,
              (Ptr{Cvoid}, Ptr{Ptr{Ptr{UInt8}}}), obj_ptr, keys_out)
    n <= 0 && return result

    try
        for i in 1:n
            kp = unsafe_load(keys_out[], i)
            kp == C_NULL && continue
            key = unsafe_string(kp)
            val_ptr = ccall(_sym("sr_object_get"), Ptr{Cvoid},
                            (Ptr{Cvoid}, Cstring), obj_ptr, key)
            val_ptr == C_NULL && continue
            result[key] = _parse_sr_value(val_ptr)
        end
    finally
        ccall(_sym("sr_free_string_arr"), Cvoid,
              (Ptr{Ptr{UInt8}}, Cint), keys_out[], n)
    end
    return result
end

function _cstring_to_string(s::Cstring)::String
    s == C_NULL && return ""
    return unsafe_string(s)
end

# sr_value_t tag constants (match sr_value_t_Tag enum)
const C_VALUE_NONE     = Int32(0)
const C_VALUE_NULL     = Int32(1)
const C_VALUE_BOOL     = Int32(2)
const C_VALUE_NUMBER   = Int32(3)
const C_VALUE_STRAND   = Int32(4)
const C_VALUE_DURATION = Int32(5)
const C_VALUE_DATETIME = Int32(6)
const C_VALUE_UUID     = Int32(7)
const C_VALUE_ARRAY    = Int32(8)
const C_VALUE_OBJECT   = Int32(9)
const C_GEOMETRY_OBJECT = Int32(10)
const C_VALUE_BYTES    = Int32(11)
const C_VALUE_THING    = Int32(12)

# Credentials scope enum values (match sr_credentials_scope)
const SCOPE_ROOT      = Cint(0)
const SCOPE_NAMESPACE = Cint(1)
const SCOPE_DATABASE  = Cint(2)
const SCOPE_RECORD    = Cint(3)

# Symbol / string / int → Cint dispatch table. Same shape pattern as
# embedded.jl's `_RPC_ARMS` — data table beats branch chain.
const _SCOPE_MAP = Dict{Any, Cint}(
    :ROOT      => SCOPE_ROOT,      "ROOT"      => SCOPE_ROOT,      0 => SCOPE_ROOT,
    :NAMESPACE => SCOPE_NAMESPACE, "NAMESPACE" => SCOPE_NAMESPACE, 1 => SCOPE_NAMESPACE,
    :DATABASE  => SCOPE_DATABASE,  "DATABASE"  => SCOPE_DATABASE,  2 => SCOPE_DATABASE,
    :RECORD    => SCOPE_RECORD,    "RECORD"    => SCOPE_RECORD,    3 => SCOPE_RECORD,
)

# --- Helpers ---

function _to_scope_enum(scope)::Cint
    v = get(_SCOPE_MAP, scope, nothing)
    isnothing(v) && throw(EmbeddedFFIError("_to_scope_enum",
        "Unknown scope: $scope. Use :ROOT, :NAMESPACE, :DATABASE, or :RECORD"))
    return v
end

# --- Memory management ---

function free_string(s::Cstring)::Nothing
    s == C_NULL && return nothing
    !_is_loaded() && return nothing
    ccall(_sym("sr_free_string"), Cvoid, (Cstring,), s)
    return nothing
end

# --- SrObject helpers (minimal, uses libsurreal constructors) ---

function _object_new()::SrObject
    return ccall(_sym("sr_object_new"), SrObject, ())
end

function _object_insert_str!(obj::SrObject, key::String, value::String)
    ccall(_sym("sr_object_insert_str"), Cvoid, (Ref{SrObject}, Cstring, Cstring), obj, key, value)
    return nothing
end

function _object_insert_int!(obj::SrObject, key::String, value::Integer)
    ccall(_sym("sr_object_insert_int"), Cvoid, (Ref{SrObject}, Cstring, Cint), obj, key, Int32(value))
    return nothing
end

function _object_insert_float!(obj::SrObject, key::String, value::AbstractFloat)
    ccall(_sym("sr_object_insert_double"), Cvoid, (Ref{SrObject}, Cstring, Cdouble), obj, key, Float64(value))
    return nothing
end

function _free_object(obj::SrObject)
    !_is_loaded() && return nothing
    ccall(_sym("sr_free_object"), Cvoid, (SrObject,), obj)
    return nothing
end

function _free_object_ptr(p::Ptr{Cvoid})
    p == C_NULL && return
    obj = unsafe_load(Ptr{SrObject}(p))
    _free_object(obj)
end

# Convert Dict{String, Any} → SrObject using libsurreal constructors
function _dict_to_object(d)::SrObject
    obj = _object_new()
    for (k, v) in d
        if v isa String
            _object_insert_str!(obj, k, v)
        elseif v isa Bool
            _object_insert_str!(obj, k, v ? "true" : "false")
        elseif v isa AbstractFloat
            _object_insert_float!(obj, k, v)
        elseif v isa Integer
            _object_insert_int!(obj, k, v)
        else
            _object_insert_str!(obj, k, string(v))
        end
    end
    return obj
end

# --- Build sr_value_t from a Julia value ---
#
# Returns an owning `Ptr{Cvoid}` (sr_value_t*). Caller MUST call
# `ccall(_sym("sr_value_free"), ...)` after use to avoid leaking. Used by
# `sr_patch_add` / `sr_patch_replace` / `sr_set` and the embedded patch path.
#
# Coverage: nothing → none, missing → null, Bool → bool, Integer → int (Int64),
# AbstractFloat → float, String → string, Vector{UInt8} → bytes, RecordID →
# thing, AbstractDict → object (built via `_dict_to_object`).
# Arrays of arbitrary values are not supported (push via `sr_array_push`
# requires recursive sr_value_t allocations; add when a real call site needs
# it).
function _julia_to_sr_value(val)::Ptr{Cvoid}
    if isnothing(val)
        return ccall(_sym("sr_value_none"), Ptr{Cvoid}, ())
    elseif val === missing
        return ccall(_sym("sr_value_null"), Ptr{Cvoid}, ())
    elseif val isa Bool
        return ccall(_sym("sr_value_bool"), Ptr{Cvoid}, (Bool,), val)
    elseif val isa Integer
        return ccall(_sym("sr_value_int"), Ptr{Cvoid}, (Int64,), Int64(val))
    elseif val isa AbstractFloat
        return ccall(_sym("sr_value_float"), Ptr{Cvoid}, (Float64,), Float64(val))
    elseif val isa AbstractString
        return ccall(_sym("sr_value_string"), Ptr{Cvoid}, (Cstring,), String(val))
    elseif val isa Vector{UInt8}
        GC.@preserve val return ccall(_sym("sr_value_bytes"), Ptr{Cvoid}, (Ptr{UInt8}, Cint),
                     pointer(val), Cint(length(val)))
    elseif val isa AbstractDict
        obj = _dict_to_object(val)
        # sr_value_object takes `const sr_object_t*`. We hold the SrObject by
        # value (single pointer field), so pass a Ref{SrObject} as the address.
        ref = Ref(obj)
        ptr = ccall(_sym("sr_value_object"), Ptr{Cvoid},
                    (Ptr{SrObject},), ref)
        return ptr
    elseif val isa Any  # RecordID guarded by name to avoid ordering issues at module load
        if hasproperty(val, :table) && hasproperty(val, :id)
            return ccall(_sym("sr_value_thing"), Ptr{Cvoid},
                         (Cstring, Cstring),
                         String(val.table), string(val.id))
        end
    end
    throw(EmbeddedFFIError("_julia_to_sr_value", "unsupported value type $(typeof(val))"))
end

# --- Notification parser ---
#
# `sr_notification_t` layout (from surrealdb.h):
#   offset  0: sr_uuid_t query_id    (16 bytes, uint8[16])
#   offset 16: enum sr_action action (4 bytes Cint, +4 padding for sr_value_t alignment)
#   offset 24: sr_value_t data       (48 bytes — see _DEFAULT_SR_VALUE_STRIDE)
#
# Total: 24 + sizeof(sr_value_t) = 72 bytes (default).
# Action enum order: CREATE=0, UPDATE=1, DELETE=2, KILLED=3, UNIMPLEMENTED=4.
const _NOTIF_ACTION_NAMES = (:CREATE, :UPDATE, :DELETE, :KILLED, :UNIMPLEMENTED)
const _NOTIF_VALUE_OFFSET = 24

function _parse_sr_notification(buf::Vector{UInt8})::Dict{String, Any}
    length(buf) >= _NOTIF_VALUE_OFFSET + Int(_sizeof_sr_value()) || throw(EmbeddedFFIError(
        "_parse_sr_notification",
        "buffer too small ($(length(buf)) bytes, need ≥$(_NOTIF_VALUE_OFFSET + Int(_sizeof_sr_value())))"))

    # Query ID — 16 raw bytes
    uuid_bytes = buf[1:16]
    uuid_str = string(UUIDs.UUID(uuid_bytes))

    # Action enum — Cint at offset 16
    action_int = reinterpret(Int32, buf[17:20])[1]
    action_sym = (action_int >= 0 && action_int < length(_NOTIF_ACTION_NAMES)) ?
        _NOTIF_ACTION_NAMES[action_int + 1] : :UNIMPLEMENTED

    # sr_value_t starts at offset 24 — parse via the existing _parse_sr_value
    # which expects a pointer to the struct's tag.
    # GC.@preserve pins buf across the nested ccalls inside _parse_sr_value
    # (sr_array_len, sr_array_get, sr_object_keys) that can trigger GC.
    parsed = GC.@preserve buf _parse_sr_value(pointer(buf) + _NOTIF_VALUE_OFFSET)

    return Dict{String, Any}(
        "query_id" => uuid_str,
        "action" => string(action_sym),
        "result" => parsed,
    )
end

# -- Connection ---

function sr_connect(endpoint::String)::Ptr{Cvoid}
    err = Ref{Cstring}(C_NULL)
    surreal = Ref{Ptr{Cvoid}}(C_NULL)
    ret = ccall(_sym("sr_connect"), Cint, (Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring), err, surreal, endpoint)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_connect", err_msg))
    end
    return surreal[]
end

function sr_disconnect(db::Ptr{Cvoid})::Nothing
    # C function name is sr_surreal_disconnect
    ccall(_sym("sr_surreal_disconnect"), Cvoid, (Ptr{Cvoid},), db)
    return nothing
end

function sr_use_ns(db::Ptr{Cvoid}, ns::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_use_ns"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, ns)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_use_ns", err_msg))
    end
    return nothing
end

function sr_use_db(db::Ptr{Cvoid}, db_name::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_use_db"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, db_name)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_use_db", err_msg))
    end
    return nothing
end

# --- Auth ---

function sr_signin(db::Ptr{Cvoid}, scope, username::String, password::String,
                   ns::String, database::String, access::String)::String

    scope_val = _to_scope_enum(scope)

    # Keep cconvert results alive so Cstring pointers don't dangle
    u = Base.cconvert(Cstring, username)
    p = Base.cconvert(Cstring, password)
    creds = SrCredentials(Base.unsafe_convert(Cstring, u), Base.unsafe_convert(Cstring, p))
    creds_ref = Ref(creds)

    if scope_val != SCOPE_ROOT
        nsc = Base.cconvert(Cstring, ns)
        dbc = Base.cconvert(Cstring, database)
        acc = Base.cconvert(Cstring, access)
        details = SrCredentialsAccess(
            Base.unsafe_convert(Cstring, nsc),
            Base.unsafe_convert(Cstring, dbc),
            Base.unsafe_convert(Cstring, acc),
        )
        details_ref = Ref(details)
    else
        details_ref = Ref(SrCredentialsAccess(C_NULL, C_NULL, C_NULL))
    end

    err = Ref{Cstring}(C_NULL)
    token = Ref{Cstring}(C_NULL)
    scope_ref = Ref{Cint}(scope_val)

    # GC.@preserve pins creds_ref, details_ref, and scope_ref across the ccall
    # so the pointers extracted via unsafe_convert remain valid.
    GC.@preserve creds_ref details_ref scope_ref begin
        scope_p  = Base.unsafe_convert(Ptr{Cint}, scope_ref)
        creds_p  = Base.unsafe_convert(Ptr{SrCredentials}, creds_ref)
        details_p = scope_val == SCOPE_ROOT ?
            Ptr{SrCredentialsAccess}(C_NULL) :
            Base.unsafe_convert(Ptr{SrCredentialsAccess}, details_ref)
        ret = ccall(_sym("sr_signin"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Cstring}, Ptr{Cint}, Ptr{SrCredentials}, Ptr{SrCredentialsAccess}, Ptr{Cvoid}),
                    db, err, token, scope_p, creds_p, details_p, C_NULL)
    end
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_signin", err_msg))
    end
    result = token[] != C_NULL ? unsafe_string(token[]) : ""
    if token[] != C_NULL; free_string(token[]); end
    return result
end

function sr_signup(db::Ptr{Cvoid}, scope, username::String, password::String,
                   ns::String, db_name::String, access::String)::String

    scope_val = _to_scope_enum(scope)

    uc = Base.cconvert(Cstring, username)
    pc = Base.cconvert(Cstring, password)
    creds = SrCredentials(Base.unsafe_convert(Cstring, uc), Base.unsafe_convert(Cstring, pc))
    creds_ref = Ref(creds)

    if scope_val != SCOPE_ROOT
        nsc = Base.cconvert(Cstring, ns)
        dbc = Base.cconvert(Cstring, db_name)
        acc = Base.cconvert(Cstring, access)
        details = SrCredentialsAccess(
            Base.unsafe_convert(Cstring, nsc),
            Base.unsafe_convert(Cstring, dbc),
            Base.unsafe_convert(Cstring, acc),
        )
        details_ref = Ref(details)
    else
        details_ref = Ref(SrCredentialsAccess(C_NULL, C_NULL, C_NULL))
    end

    err = Ref{Cstring}(C_NULL)
    token = Ref{Cstring}(C_NULL)
    scope_ref = Ref{Cint}(scope_val)

    GC.@preserve creds_ref details_ref scope_ref begin
        scope_p   = Base.unsafe_convert(Ptr{Cint}, scope_ref)
        creds_p   = Base.unsafe_convert(Ptr{SrCredentials}, creds_ref)
        details_p = scope_val == SCOPE_ROOT ?
            Ptr{SrCredentialsAccess}(C_NULL) :
            Base.unsafe_convert(Ptr{SrCredentialsAccess}, details_ref)
        ret = ccall(_sym("sr_signup"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Cstring}, Ptr{Cint}, Ptr{SrCredentials}, Ptr{SrCredentialsAccess}, Ptr{Cvoid}),
                    db, err, token, scope_p, creds_p, details_p, C_NULL)
    end
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_signup", err_msg))
    end
    result = token[] != C_NULL ? unsafe_string(token[]) : ""
    if token[] != C_NULL; free_string(token[]); end
    return result
end

function sr_authenticate(db::Ptr{Cvoid}, token::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_authenticate"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, token)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_authenticate", err_msg))
    end
    return nothing
end

function sr_invalidate(db::Ptr{Cvoid})::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_invalidate"), Cint, (Ptr{Cvoid}, Ptr{Cstring}), db, err)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_invalidate", err_msg))
    end
    return nothing
end

# --- Query + CRUD ---

function sr_query(db::Ptr{Cvoid}, query::String, vars)::Vector{Any}
    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    var_obj = _dict_to_object(vars)
    var_ref = Ref(var_obj)
    ret = ccall(_sym("sr_query"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, query, var_ref)
    _free_object(var_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_query", err_msg))
    end
    if res[] != C_NULL
        arr_res = unsafe_load(Ptr{SrArrRes}(res[]))
        if arr_res.err_code != 0
            emsg = arr_res.err_msg != C_NULL ? unsafe_string(arr_res.err_msg) : "query error"
            ccall(_sym("sr_free_arr_res"), Cvoid, (SrArrRes,), arr_res)
            throw(EmbeddedFFIError("sr_query", emsg))
        end
        n = arr_res.ok_len
        ok_ptr = arr_res.ok_arr
        stride = Int(_sizeof_sr_value())
        result = Any[]
        for i in 0:n-1
            elem = ok_ptr + i * stride
            push!(result, _parse_sr_value(elem))
        end
        ccall(_sym("sr_free_arr_res"), Cvoid, (SrArrRes,), arr_res)
        return result
    end
    return Any[]
end

const _SRVALUE_SIZE = Ref{Csize_t}(0)

# Default sr_value_t stride for the surrealdb.c build pinned in deps/build_libsurreal.jl.
# The C library does not expose `sr_sizeof_value()`; the size is a build-time
# invariant of `sr_value_t` (tag + padding + largest union member). The
# `_self_test_layout()` probe (run from `load!()`) validates the assumption
# against known sr_value_int / sr_value_string / array round-trips before user
# code sees any silent corruption. Override via `SURREALDB_VALUE_STRIDE` env if
# a future libsurreal build changes the layout and the probe doesn't catch it.
const _DEFAULT_SR_VALUE_STRIDE = Csize_t(48)

function _sizeof_sr_value()::Csize_t
    if _SRVALUE_SIZE[] == 0
        override = get(ENV, "SURREALDB_VALUE_STRIDE", "")
        _SRVALUE_SIZE[] = isempty(override) ? _DEFAULT_SR_VALUE_STRIDE : Csize_t(parse(Int, override))
    end
    return _SRVALUE_SIZE[]
end

# Layout self-test: build a known sr_value_t, parse it, verify the result.
# Called from `load!()` to catch layout drift after a libsurreal upgrade.
# Throws `EmbeddedFFIError`-shaped error on mismatch (typed errors land in R17).
function _self_test_layout()
    # 1. Scalar int round-trip — verifies tag-at-offset-0 + Number-tag-at-offset-8 + Int64-at-offset-16
    p_int = ccall(_sym("sr_value_int"), Ptr{Cvoid}, (Int64,), 42)
    p_int == C_NULL && throw(EmbeddedFFIError("_self_test_layout", "sr_value_int(42) returned NULL"))
    try
        v = _parse_sr_value(p_int)
        v == 42 || throw(EmbeddedFFIError("_self_test_layout", "sr_value_int(42) parsed as $(repr(v)) ≠ 42 — sr_value_t layout has changed; set SURREALDB_VALUE_STRIDE or rebuild against a compatible surrealdb.c"))
    finally
        ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), p_int)
    end

    # 2. String round-trip — verifies String variant + Cstring offset
    s = "hello"
    p_str = ccall(_sym("sr_value_string"), Ptr{Cvoid}, (Cstring,), s)
    p_str == C_NULL && throw(EmbeddedFFIError("_self_test_layout", "sr_value_string(\"hello\") returned NULL"))
    try
        v = _parse_sr_value(p_str)
        v == "hello" || throw(EmbeddedFFIError("_self_test_layout", "sr_value_string(\"hello\") parsed as $(repr(v)) — string layout has changed"))
    finally
        ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), p_str)
    end

    # 3. Bool round-trip — verifies Bool variant
    p_bool = ccall(_sym("sr_value_bool"), Ptr{Cvoid}, (Bool,), true)
    p_bool == C_NULL && throw(EmbeddedFFIError("_self_test_layout", "sr_value_bool(true) returned NULL"))
    try
        v = _parse_sr_value(p_bool)
        v === true || throw(EmbeddedFFIError("_self_test_layout", "sr_value_bool(true) parsed as $(repr(v)) — bool layout has changed"))
    finally
        ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), p_bool)
    end

    # Note: stride between consecutive sr_value_t in a C array (the load-bearing
    # assumption for `_parse_sr_value_array`) is NOT directly probeable here
    # because the constructors return individually-allocated boxes. CRUD-op
    # tests in test/test_embedded.jl (R3) catch stride drift in practice — any
    # multi-row SELECT will surface it as a tag misread on the second element.
    return nothing
end

# Parse an array of sr_value_t elements returned by CRUD functions
function _parse_sr_value_array(arr_ptr::Ptr{Cvoid}, n::Integer)::Vector{Any}
    if arr_ptr == C_NULL || n <= 0
        return Any[]
    end
    stride = Int(_sizeof_sr_value())
    result = Any[]
    sizehint!(result, n)
    for i in 0:n-1
        elem = arr_ptr + i * stride
        push!(result, _parse_sr_value(elem))
    end
    return result
end

function sr_create(db, resource::String, content)::Any
    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_create"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, resource, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_create", err_msg))
    end
    if res[] != C_NULL
        result = _parse_sr_object(res[])
        _free_object_ptr(res[])
        return result
    end
    return nothing
end

function sr_select(db, resource::String)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    ret = ccall(_sym("sr_select"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring),
                db, err, res, resource)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_select", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_update(db, resource::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_update"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, resource, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_update", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_delete(db, resource::String)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    ret = ccall(_sym("sr_delete"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring),
                db, err, res, resource)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_delete", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_insert(db, table::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_insert"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, table, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_insert", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_upsert(db, resource::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_upsert"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, resource, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_upsert", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_merge(db, resource::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_merge"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, resource, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_merge", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_patch_add(db, resource::String, path::String, value)::Any
    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    val_ptr = _julia_to_sr_value(value)
    try
        ret = ccall(_sym("sr_patch_add"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Cstring, Ptr{Cvoid}),
                    db, err, res, resource, path, val_ptr)
        if ret < 0
            err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
            if err[] != C_NULL; free_string(err[]); end
            throw(EmbeddedFFIError("sr_patch_add", err_msg))
        end
        n = ret
        if res[] != C_NULL
            result = _parse_sr_value_array(res[], n)
            ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
            return result
        end
        return Any[]
    finally
        val_ptr != C_NULL && ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), val_ptr)
    end
end

function sr_patch_remove(db, resource::String, path::String)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    ret = ccall(_sym("sr_patch_remove"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Cstring),
                db, err, res, resource, path)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_patch_remove", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_patch_replace(db, resource::String, path::String, value)::Any
    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    val_ptr = _julia_to_sr_value(value)
    try
        ret = ccall(_sym("sr_patch_replace"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Cstring, Ptr{Cvoid}),
                    db, err, res, resource, path, val_ptr)
        if ret < 0
            err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
            if err[] != C_NULL; free_string(err[]); end
            throw(EmbeddedFFIError("sr_patch_replace", err_msg))
        end
        n = ret
        if res[] != C_NULL
            result = _parse_sr_value_array(res[], n)
            ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
            return result
        end
        return Any[]
    finally
        val_ptr != C_NULL && ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), val_ptr)
    end
end

function sr_relate(db, from::String, relation::String, to::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    if content isa AbstractDict
        content_obj = _dict_to_object(content)
        content_ref = Ref(content_obj)
        ret = ccall(_sym("sr_relate"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Cstring, Cstring, Ref{SrObject}),
                    db, err, res, from, relation, to, content_ref)
        _free_object(content_obj)
    else
        ret = ccall(_sym("sr_relate"), Cint,
                    (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Cstring, Cstring, Ptr{Cvoid}),
                    db, err, res, from, relation, to, C_NULL)
    end
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_relate", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

function sr_insert_relation(db, table::String, content)::Any

    err = Ref{Cstring}(C_NULL)
    res = Ref{Ptr{Cvoid}}(C_NULL)
    content_obj = content isa AbstractDict ? _dict_to_object(content) : _dict_to_object(Dict{String, Any}())
    content_ref = Ref(content_obj)
    ret = ccall(_sym("sr_insert_relation"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring, Ref{SrObject}),
                db, err, res, table, content_ref)
    _free_object(content_obj)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_insert_relation", err_msg))
    end
    n = ret
    if res[] != C_NULL
        result = _parse_sr_value_array(res[], n)
        ccall(_sym("sr_free_arr"), Cvoid, (Ptr{Cvoid}, Cint), res[], n)
        return result
    end
    return Any[]
end

# --- Live queries ---

function sr_select_live(db::Ptr{Cvoid}, resource::String)::Ptr{Cvoid}

    err = Ref{Cstring}(C_NULL)
    stream = Ref{Ptr{Cvoid}}(C_NULL)
    ret = ccall(_sym("sr_select_live"), Cint,
                (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Ptr{Cvoid}}, Cstring),
                db, err, stream, resource)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_select_live", err_msg))
    end
    return stream[]
end

function sr_stream_next(stream::Ptr{Cvoid})::Union{Dict,Nothing}
    # sr_notification_t = uuid (16) + action (4) + 4 pad + sr_value_t (48) = 72 bytes
    # Allocate generously to tolerate any future stride increase the self-test
    # didn't catch; only the first 72 bytes are touched by the C side.
    buf = zeros(UInt8, 256)
    ret = GC.@preserve buf ccall(_sym("sr_stream_next"), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), stream, pointer(buf))
    # ret > 0: data available; 0 / SR_NONE: stream closed; <0: error
    if ret <= 0
        return nothing
    end
    return _parse_sr_notification(buf)
end

function sr_stream_kill(stream::Ptr{Cvoid})::Nothing
    ccall(_sym("sr_stream_kill"), Cvoid, (Ptr{Cvoid},), stream)
    return nothing
end

function sr_kill(db::Ptr{Cvoid}, query_id::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_kill"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, query_id)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_kill", err_msg))
    end
    return nothing
end

# --- Session variables ---

function sr_set(db::Ptr{Cvoid}, key::String, value)::Nothing
    err = Ref{Cstring}(C_NULL)
    val_ptr = _julia_to_sr_value(value)
    try
        ret = ccall(_sym("sr_set"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring, Ptr{Cvoid}), db, err, key, val_ptr)
        if ret < 0
            err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
            if err[] != C_NULL; free_string(err[]); end
            throw(EmbeddedFFIError("sr_set", err_msg))
        end
    finally
        val_ptr != C_NULL && ccall(_sym("sr_value_free"), Cvoid, (Ptr{Cvoid},), val_ptr)
    end
    return nothing
end

function sr_unset(db::Ptr{Cvoid}, key::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_unset"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, key)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_unset", err_msg))
    end
    return nothing
end

# --- Transactions ---

function sr_begin(db::Ptr{Cvoid})::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_begin"), Cint, (Ptr{Cvoid}, Ptr{Cstring}), db, err)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_begin", err_msg))
    end
    return nothing
end

function sr_commit(db::Ptr{Cvoid})::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_commit"), Cint, (Ptr{Cvoid}, Ptr{Cstring}), db, err)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_commit", err_msg))
    end
    return nothing
end

function sr_cancel(db::Ptr{Cvoid})::Nothing

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_cancel"), Cint, (Ptr{Cvoid}, Ptr{Cstring}), db, err)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_cancel", err_msg))
    end
    return nothing
end

# --- Meta ---

function sr_version(db::Ptr{Cvoid})::String

    err = Ref{Cstring}(C_NULL)
    ver = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_version"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Ptr{Cstring}), db, err, ver)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_version", err_msg))
    end
    result = ver[] != C_NULL ? unsafe_string(ver[]) : ""
    if ver[] != C_NULL; free_string(ver[]); end
    return result
end

function sr_health(db::Ptr{Cvoid})::Bool

    err = Ref{Cstring}(C_NULL)
    ret = ccall(_sym("sr_health"), Cint, (Ptr{Cvoid}, Ptr{Cstring}), db, err)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_health", err_msg))
    end
    return true
end

function sr_export_db(db::Ptr{Cvoid}, filepath::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    # C function name is sr_export (not sr_export_db)
    ret = ccall(_sym("sr_export"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, filepath)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_export", err_msg))
    end
    return nothing
end

function sr_import_db(db::Ptr{Cvoid}, filepath::String)::Nothing

    err = Ref{Cstring}(C_NULL)
    # C function name is sr_import (not sr_import_db)
    ret = ccall(_sym("sr_import"), Cint, (Ptr{Cvoid}, Ptr{Cstring}, Cstring), db, err, filepath)
    if ret < 0
        err_msg = err[] != C_NULL ? unsafe_string(err[]) : "unknown error"
        if err[] != C_NULL; free_string(err[]); end
        throw(EmbeddedFFIError("sr_import", err_msg))
    end
    return nothing
end

end # module LibSurreal

"""
    libsurreal_load!(path::String="")

Load the `libsurreal` shared library at `path` for embedded mode. When
`path` is empty, falls back to the `SURREALDB_LIB` environment variable.

Must be called before `connect("mem://")` or `connect("surrealkv://...")`.
Remote connections (`ws://`, `http://`) don't need this.

# Examples
```julia
SurrealDB.libsurreal_load!("/path/to/libsurrealdb_c.dylib")
db = SurrealDB.connect("mem://")
```
"""
function libsurreal_load!(path::String="")
    LibSurreal.load!(path)
    return nothing
end
