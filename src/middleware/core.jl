abstract type AbstractMiddleware end

"""
    HandlerContext(manager::SessionManager)

Context shared across the entire lifespan of a connection or server handler.
Contains the `SessionManager` that tracks all active sessions.
"""
struct HandlerContext
    manager::SessionManager
end

"""
    RequestContext(manager::SessionManager, emitted::Vector{Dict{String, Any}}, session::Union{ModuleSession, NamedSession, Nothing})

Context associated with a single incoming request. Tracks the `manager`, the
list of `emitted` responses generated so far, and the `session` active for
the request (if any).
"""
mutable struct RequestContext
    manager::SessionManager
    emitted::Vector{Dict{String, Any}}
    session::Union{ModuleSession, NamedSession, Nothing}
end

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
    return AbstractMiddleware[SessionMiddleware(), SessionOpsMiddleware(), DescribeMiddleware(), EvalMiddleware(), UnknownOpMiddleware()]
end

function build_handler(; manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack())
    connection_ctx = HandlerContext(manager)
    return function(msg::AbstractDict)
        validation_error = validate_request(msg)
        !isnothing(validation_error) && return [validation_error]

        request_id = String(get(msg, "id", ""))
        ctx = RequestContext(connection_ctx.manager, Dict{String, Any}[], nothing)
        result = dispatch_middleware(middleware, 1, msg, ctx)
        return finalize_responses(ctx, result, request_id)
    end
end
