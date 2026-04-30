# Lookup middleware — handles `op == "lookup"` requests and returns symbol
# documentation and method information for Julia symbols.

"""
    LookupMiddleware

Middleware that handles `op == "lookup"` requests. Resolves the `symbol` field
in the optional `module` context (defaulting to the session module or `Main`),
returns documentation and method signatures when found, and returns
`"found" => false` when the symbol does not exist. All other ops are forwarded.
"""
struct LookupMiddleware <: AbstractMiddleware end

descriptor(::LookupMiddleware) = MiddlewareDescriptor(
    provides = Set(["lookup"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "lookup" => Dict{String, Any}(
            "doc"      => "Look up Julia symbol documentation.",
            "requires" => ["symbol"],
            "optional" => ["session", "module"],
            "returns"  => ["doc"],
        ),
    ),
)

function handle_message(::LookupMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "lookup" || return next(msg)
    return lookup_responses(ctx, msg)
end

function lookup_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])

    symbol_str = get(request, "symbol", nothing)
    symbol_str isa AbstractString || return [error_response(request_id, "lookup requires a string symbol field")]

    module_name = get(request, "module", nothing)
    if !isnothing(module_name) && !(module_name isa AbstractString)
        return [error_response(request_id, "lookup module must be a string when provided")]
    end

    # Resolve lookup module: explicit module > session module > Main.
    lookup_mod = _resolve_lookup_module(module_name, ctx)

    result = _lookup_symbol(symbol_str, lookup_mod)

    return [
        response_message(request_id,
            (k => v for (k, v) in pairs(result))...
        ),
        done_response(request_id),
    ]
end

function _resolve_lookup_module(module_name, ctx::RequestContext)
    if !isnothing(module_name)
        mod = _traverse_module_path(module_name)
        return something(mod, session_module(ctx.session))
    end
    return session_module(ctx.session)
end

# Walk a dotted module path (e.g. "Base.Math") using getfield only — no eval.
# Returns nothing if any segment is missing, not a module, or not a valid identifier.
function _traverse_module_path(path::AbstractString)::Union{Module, Nothing}
    parts = split(path, '.')
    isempty(parts) && return nothing
    all(p -> Base.isidentifier(String(p)), parts) || return nothing
    sym = Symbol(parts[1])
    isdefined(Main, sym) || return nothing
    mod = getfield(Main, sym)
    mod isa Module || return nothing
    for part in parts[2:end]
        s = Symbol(part)
        isdefined(mod, s) || return nothing
        child = getfield(mod, s)
        child isa Module || return nothing
        mod = child
    end
    return mod
end

function _lookup_symbol(symbol_str::AbstractString, module_::Module)
    # Reject non-identifier strings to prevent expression injection.
    if !Base.isidentifier(symbol_str)
        return Dict{String, Any}("found" => false)
    end
    sym = Symbol(symbol_str)
    value = try
        isdefined(module_, sym) || return Dict{String, Any}("found" => false)
        getfield(module_, sym)
    catch
        return Dict{String, Any}("found" => false)
    end

    doc_str = safe_render("doc", _render_doc, value)
    type_str = string(typeof(value))

    method_list = try
        [string(m) for m in methods(value)]
    catch
        String[]
    end

    return Dict{String, Any}(
        "found" => true,
        "name" => symbol_str,
        "type" => type_str,
        "doc" => doc_str,
        "methods" => method_list,
    )
end

function _render_doc(value)
    doc_result = Base.Docs.doc(value)
    return sprint(show, MIME("text/plain"), doc_result)
end
