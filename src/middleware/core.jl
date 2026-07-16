abstract type AbstractMiddleware end

"""
    MiddlewareDescriptor(; provides, requires, expects, op_info)

Metadata describing a middleware's interface contract used for startup validation
and dynamic describe responses.

- `provides::Set{String}` — operation names (e.g. `"eval"`) this middleware handles.
- `requires::Set{String}` — names that must be provided by some *earlier* middleware in the stack.
- `expects::Vector{String}` — human-readable ordering constraints (informational; not enforced by `validate_stack`).
- `op_info::Dict{String, Dict{String, Any}}` — per-op metadata (doc, requires, optional, returns) used to build describe responses dynamically.
"""
@kwdef struct MiddlewareDescriptor
    provides::Set{String}  = Set{String}()
    requires::Set{String}  = Set{String}()
    expects::Vector{String} = String[]
    op_info::Dict{String, Dict{String, Any}} = Dict{String, Dict{String, Any}}()
end

"""
    descriptor(mw::AbstractMiddleware) -> MiddlewareDescriptor

Return the `MiddlewareDescriptor` for `mw`. The default makes no claims.
Override to declare what ops a middleware provides/requires.
"""
descriptor(::AbstractMiddleware) = MiddlewareDescriptor()
shutdown_middleware!(::AbstractMiddleware) = nothing

"""
    validate_stack(stack) -> Vector{String}

Validate a middleware stack and return a (possibly empty) list of error strings.

Checks:
- **Duplicate provides**: two or more middlewares claiming the same op name.
- **Unsatisfied requires**: a middleware requiring a name not provided by any *earlier* middleware.

Note: `validate_stack` is not called automatically by `build_handler`. Call it explicitly
at server startup (or in tests) to verify a custom stack before use.
"""
function validate_stack(stack::Vector{<:AbstractMiddleware})
    errors = String[]
    seen_provides = Dict{String, Int}()   # op name → first-seen stack index
    accumulated   = Set{String}()         # all ops provided up to (not incl.) current mw

    for (i, mw) in enumerate(stack)
        desc = descriptor(mw)

        # Check requires against what's been provided so far
        for req in sort!(collect(desc.requires))
            req in accumulated || push!(errors, "Middleware at index $i requires '$req' but no earlier middleware provides it")
        end

        # Check for duplicate provides
        for op in sort!(collect(desc.provides))
            if haskey(seen_provides, op)
                push!(errors, "Duplicate handler for '$op': middleware at indices $(seen_provides[op]) and $i")
            else
                seen_provides[op] = i
            end
        end

        union!(accumulated, desc.provides)
    end

    return errors
end

"""
    HandlerContext(manager::SessionManager)

Context shared across the entire lifespan of a connection or server handler.
Contains the `SessionManager` that tracks all active sessions.
"""
struct HandlerContext
    manager::SessionManager
end

"""
    RequestContext(manager, emitted, session, server_state)

Context associated with a single incoming request. Tracks the `manager`, the
list of `emitted` responses generated so far, the `session` active for
the request (if any), and the `server_state` (shared server-wide limits and counters).
`server_state` is `nothing` when `build_handler` is called without a `state` argument
(e.g. in unit tests that don't need limit enforcement).
"""
mutable struct RequestContext
    manager::SessionManager
    emitted::Vector{Dict{String, Any}}
    session::Union{ModuleSession, NamedSession, Nothing}
    server_state::Union{ServerState, Nothing}
    emit_stream::Union{Channel{Dict{String, Any}}, Nothing}
end

RequestContext(manager::SessionManager, emitted::Vector{Dict{String, Any}}, session) =
    RequestContext(manager, emitted, session, nothing, nothing)

RequestContext(manager::SessionManager, emitted::Vector{Dict{String, Any}}, session, server_state) =
    RequestContext(manager, emitted, session, server_state, nothing)

emit!(ctx::RequestContext, msg::Dict{String, Any}) = push!(ctx.emitted, msg)

handle_message(::AbstractMiddleware, msg, next, ctx::RequestContext) = next(msg)

"""
    dispatch_middleware(stack::Vector{<:AbstractMiddleware}, index::Int, msg, ctx::RequestContext)

Recursively process `msg` through the middleware `stack` starting at `index`.
Each middleware piece can choose to forward the message to the `next` piece in the chain
or handle it immediately and return early. The final responses are typically accumulated
in `ctx.emitted` or returned directly.
"""
function dispatch_middleware(stack::Vector{<:AbstractMiddleware}, index::Int, msg, ctx::RequestContext)
    index > length(stack) && return nothing
    next = next_msg -> dispatch_middleware(stack, index + 1, next_msg, ctx)
    return handle_message(stack[index], msg, next, ctx)
end

# Tuple-based dispatch used by `build_handler`. Because the stack is a
# heterogeneous `Tuple` of concrete middleware types, `first(stack)` and
# `Base.tail(stack)` have concrete types at each step, so `handle_message`
# resolves statically (no method-table lookup per middleware) and the chain can
# be inlined/unrolled. The `next` continuation captures the concrete tuple tail
# and `ctx`, so it stays type-stable. Behavior matches the Vector form; the
# exported `dispatch_middleware(::Vector, ::Int, ...)` above is retained for
# direct callers and tests.
dispatch_middleware(::Tuple{}, msg, ctx::RequestContext) = nothing

@inline function dispatch_middleware(stack::Tuple{M, Vararg{AbstractMiddleware}}, msg, ctx::RequestContext) where {M <: AbstractMiddleware}
    mw = first(stack)
    rest = Base.tail(stack)
    next = let rest = rest, ctx = ctx
        next_msg -> dispatch_middleware(rest, next_msg, ctx)
    end
    return handle_message(mw, msg, next, ctx)
end

"""
    mutable_copy(msg) -> Dict{String, Any}

Return a mutable `Dict{String, Any}` copy of a request `msg`, coercing keys to
`String`. Request messages arrive as a `JSON3.Object` whose keys are `Symbol`-like
and which is itself immutable, so a middleware that needs to modify a request
before forwarding cannot mutate `msg` directly. Use this helper to build the new
request:

```julia
new_msg = merge(mutable_copy(msg), Dict{String, Any}("code" => fixed))
return next(new_msg)
```
"""
mutable_copy(msg::AbstractDict) = Dict{String, Any}(string(k) => v for (k, v) in pairs(msg))

function finalize_responses(ctx::RequestContext, result, request_id::AbstractString)
    terminal = Dict{String, Any}[]
    if result isa Dict{String, Any}
        push!(terminal, result)
    elseif result isa Vector{Dict{String, Any}}
        append!(terminal, result)
    elseif !isnothing(result)
        throw(ArgumentError("unsupported middleware return value: $(typeof(result))"))
    end

    if isempty(terminal)
        push!(terminal, done_response(request_id))
    end

    return vcat(ctx.emitted, terminal)
end

function default_middleware_stack()
    return AbstractMiddleware[AuditMiddleware(AuditLog()), SessionMiddleware(), SessionOpsMiddleware(), DescribeMiddleware(), PingMiddleware(), InterruptMiddleware(), StdinMiddleware(), EvalMiddleware(), ReloadFileMiddleware(), LoadFileMiddleware(), CompleteMiddleware(), LookupMiddleware(), LsBindingsMiddleware(), UnknownOpMiddleware()]
end

function materialize_middleware_stack(middleware::Vector{<:AbstractMiddleware})
    ops_catalog = Dict{String, Any}()
    for mw in middleware
        desc = descriptor(mw)
        merge!(ops_catalog, desc.op_info)
    end
    return AbstractMiddleware[mw isa DescribeMiddleware ? DescribeMiddleware(ops_catalog) : mw for mw in middleware]
end

function build_handler(; manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(), state::Union{ServerState, Nothing}=nothing)
    # Snapshot the materialized stack as a concrete heterogeneous Tuple so the
    # per-message dispatch is statically resolved (see tuple `dispatch_middleware`).
    # The public `middleware=` Vector API is unchanged; this is an internal copy.
    stack = Tuple(materialize_middleware_stack(middleware))
    connection_ctx = HandlerContext(manager)
    return function(msg::AbstractDict, stream::Union{Channel{Dict{String, Any}}, Nothing}=nothing)
        validation_error = validate_request(msg)
        !isnothing(validation_error) && return [validation_error]

        request_id = String(get(msg, "id", ""))
        ctx = RequestContext(connection_ctx.manager, Dict{String, Any}[], nothing, state, stream)
        result = dispatch_middleware(stack, msg, ctx)
        return finalize_responses(ctx, result, request_id)
    end
end
