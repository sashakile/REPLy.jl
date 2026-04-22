abstract type AbstractMiddleware end

"""
    MiddlewareDescriptor(; provides, requires, expects)

Metadata describing a middleware's interface contract used for startup validation.

- `provides::Set{String}` — operation names (e.g. `"eval"`) this middleware handles.
- `requires::Set{String}` — names that must be provided by some *earlier* middleware in the stack.
- `expects::Vector{String}` — human-readable ordering constraints (informational; not enforced by `validate_stack`).
"""
@kwdef struct MiddlewareDescriptor
    provides::Set{String}  = Set{String}()
    requires::Set{String}  = Set{String}()
    expects::Vector{String} = String[]
end

"""
    descriptor(mw::AbstractMiddleware) -> MiddlewareDescriptor

Return the `MiddlewareDescriptor` for `mw`. The default makes no claims.
Override to declare what ops a middleware provides/requires.
"""
descriptor(::AbstractMiddleware) = MiddlewareDescriptor()

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
end

RequestContext(manager::SessionManager, emitted::Vector{Dict{String, Any}}, session) =
    RequestContext(manager, emitted, session, nothing)

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
    return AbstractMiddleware[SessionMiddleware(), SessionOpsMiddleware(), DescribeMiddleware(), InterruptMiddleware(), StdinMiddleware(), EvalMiddleware(), UnknownOpMiddleware()]
end

function build_handler(; manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(), state::Union{ServerState, Nothing}=nothing)
    connection_ctx = HandlerContext(manager)
    return function(msg::AbstractDict)
        validation_error = validate_request(msg)
        !isnothing(validation_error) && return [validation_error]

        request_id = String(get(msg, "id", ""))
        ctx = RequestContext(connection_ctx.manager, Dict{String, Any}[], nothing, state)
        result = dispatch_middleware(middleware, 1, msg, ctx)
        return finalize_responses(ctx, result, request_id)
    end
end
