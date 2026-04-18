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

function output_chunk_messages(request_id::AbstractString, stdout_text::AbstractString, stderr_text::AbstractString)
    messages = Dict{String, Any}[]
    !isempty(stdout_text) && push!(messages, response_message(request_id, "out" => stdout_text))
    !isempty(stderr_text) && push!(messages, response_message(request_id, "err" => stderr_text))
    return messages
end

function eval_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || return [error_response(request_id, "code must be a string")]

    created_session = isnothing(ctx.session)
    session = created_session ? create_ephemeral_session!(ctx.manager) : something(ctx.session)
    module_ = session_module(session)
    stdout_pipe = Pipe()
    stderr_pipe = Pipe()

    try
        value = try
            redirect_stdout(stdout_pipe) do
                redirect_stderr(stderr_pipe) do
                    if isempty(strip(code))
                        nothing
                    else
                        expr = Meta.parse(code)
                        Core.eval(module_, expr)
                    end
                end
            end
        catch ex
            close(Base.pipe_writer(stdout_pipe))
            close(Base.pipe_writer(stderr_pipe))
            output_messages = output_chunk_messages(
                request_id,
                String(read(Base.pipe_reader(stdout_pipe))),
                String(read(Base.pipe_reader(stderr_pipe))),
            )
            append!(output_messages, [eval_error_response(request_id, ex; bt=catch_backtrace())])
            return output_messages
        end

        close(Base.pipe_writer(stdout_pipe))
        close(Base.pipe_writer(stderr_pipe))
        responses = output_chunk_messages(
            request_id,
            String(read(Base.pipe_reader(stdout_pipe))),
            String(read(Base.pipe_reader(stderr_pipe))),
        )
        push!(responses, response_message(request_id, "value" => repr(value), "ns" => string(nameof(module_))))
        push!(responses, done_response(request_id))
        return responses
    finally
        created_session && destroy_session!(ctx.manager, session)
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
        validation_error = validate_request(msg)
        !isnothing(validation_error) && return [validation_error]

        request_id = String(get(msg, "id", ""))
        ctx = RequestContext(connection_ctx.manager, Dict{String, Any}[], nothing)
        result = dispatch_middleware(middleware, 1, msg, ctx)
        return finalize_responses(ctx, result, request_id)
    end
end
