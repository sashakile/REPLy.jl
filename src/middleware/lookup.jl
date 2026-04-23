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
        try
            return Core.eval(Main, Meta.parse(module_name))
        catch
            return Main
        end
    end
    return session_module(ctx.session)
end

function _lookup_symbol(symbol_str::AbstractString, module_::Module)
    value = try
        Core.eval(module_, Meta.parse(symbol_str))
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
