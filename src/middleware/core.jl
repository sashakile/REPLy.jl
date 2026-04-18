abstract type AbstractMiddleware end

struct HandlerContext
    manager::SessionManager
end

mutable struct RequestContext
    manager::SessionManager
    emitted::Vector{Dict{String, Any}}
    session::Union{ModuleSession, Nothing}
end

struct EvalMiddleware <: AbstractMiddleware end

emit!(ctx::RequestContext, msg::Dict{String, Any}) = push!(ctx.emitted, msg)

handle_message(::AbstractMiddleware, msg, next, ctx::RequestContext) = next(msg)

function emit_streams!(ctx::RequestContext, request_id::AbstractString, stdout_buffer::IOBuffer, stderr_buffer::IOBuffer)
    stdout_text = String(take!(stdout_buffer))
    stderr_text = String(take!(stderr_buffer))

    isempty(stdout_text) || emit!(ctx, response_message(request_id, "out" => stdout_text))
    isempty(stderr_text) || emit!(ctx, response_message(request_id, "err" => stderr_text))
    return nothing
end

function eval_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || return [error_response(request_id, "code must be a string")]

    session = something(ctx.session, create_ephemeral_session!(ctx.manager))
    module_ = session_module(session)

    try
        value = if isempty(strip(code))
            nothing
        else
            expr = Meta.parse(code)
            Core.eval(module_, expr)
        end

        return [
            response_message(request_id, "value" => repr(value), "ns" => string(nameof(module_))),
            done_response(request_id),
        ]
    catch ex
        return [eval_error_response(request_id, ex; bt=catch_backtrace())]
    end
end

function handle_message(::EvalMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "eval" || return next(msg)
    return eval_responses(ctx, msg)
end

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
    return AbstractMiddleware[SessionMiddleware(), EvalMiddleware(), UnknownOpMiddleware()]
end

function build_handler(; manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack())
    connection_ctx = HandlerContext(manager)
    return function(msg::AbstractDict)
        request_id = String(get(msg, "id", ""))
        ctx = RequestContext(connection_ctx.manager, Dict{String, Any}[], nothing)
        result = dispatch_middleware(middleware, 1, msg, ctx)
        return finalize_responses(ctx, result, request_id)
    end
end
