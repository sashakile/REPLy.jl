# ls-bindings middleware — handles `op == "ls-bindings"` and returns a
# structured, typed listing of the bindings defined in a session module. Lets
# an agent resuming an existing session discover current state without
# re-running eval history.

"""
    LsBindingsMiddleware

Middleware that answers `op == "ls-bindings"` with the user-defined bindings in
the target session module. For each binding it returns its `name` and `type`
(as strings), sorted by name, along with the total `count` and the module `ns`.

A `session` is required: session-less requests have no persistent bindings to
enumerate and receive an error. Auto-injected names (`eval`, `include`), gensym
names (starting with `#`, including the session module's own self-name), and
sub-modules are excluded so only user-facing session state is reported.

All other ops are forwarded to the next middleware.
"""
struct LsBindingsMiddleware <: AbstractMiddleware end

descriptor(::LsBindingsMiddleware) = MiddlewareDescriptor(
    provides = Set(["ls-bindings"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "ls-bindings" => Dict{String, Any}(
            "doc"      => "List the user-defined bindings (name and type) in a session module.",
            "requires" => ["session"],
            "optional" => String[],
            "returns"  => ["bindings", "count", "ns"],
        ),
    ),
)

# Names that always exist in a session module but are not user bindings.
const _LS_BINDINGS_EXCLUDED = Set{Symbol}([:eval, :include])

function handle_message(::LsBindingsMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "ls-bindings" || return next(msg)
    request_id = String(get(msg, "id", ""))

    session = ctx.session
    if !(session isa NamedSession)
        return [error_response(request_id, "ls-bindings requires a session")]
    end
    mod = session_module(session)

    bindings = Dict{String, Any}[]
    for sym in names(mod; all=true)
        startswith(string(sym), "#") && continue
        sym in _LS_BINDINGS_EXCLUDED && continue
        isdefined(mod, sym) || continue
        value = try
            getfield(mod, sym)
        catch
            continue
        end
        value isa Module && continue
        push!(bindings, Dict{String, Any}("name" => string(sym), "type" => string(typeof(value))))
    end
    sort!(bindings; by = b -> b["name"])

    return [
        response_message(request_id,
            "bindings" => bindings,
            "count" => length(bindings),
            "ns" => string(nameof(mod))),
        done_response(request_id),
    ]
end
