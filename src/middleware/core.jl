abstract type AbstractMiddleware end

struct HandlerContext
    manager::SessionManager
end

mutable struct RequestContext
    manager::SessionManager
    emitted::Vector{Dict{String, Any}}
    session::Union{ModuleSession, NamedSession, Nothing}
end

struct EvalMiddleware <: AbstractMiddleware end

const EVAL_IO_CAPTURE_LOCK = ReentrantLock()

emit!(ctx::RequestContext, msg::Dict{String, Any}) = push!(ctx.emitted, msg)

safe_repr(value) = safe_render("repr", repr, value)

handle_message(::AbstractMiddleware, msg, next, ctx::RequestContext) = next(msg)

function buffered_output_messages(request_id::AbstractString, stdout_text::AbstractString, stderr_text::AbstractString)
    messages = Dict{String, Any}[]
    !isempty(stdout_text) && push!(messages, response_message(request_id, "out" => stdout_text))
    !isempty(stderr_text) && push!(messages, response_message(request_id, "err" => stderr_text))
    return messages
end

function read_captured_output(io::IO)
    flush(io)
    seekstart(io)
    return read(io, String)
end

function eval_parsed(module_::Module, exprs)
    if exprs isa Expr && exprs.head == :toplevel
        value = nothing
        for expr in exprs.args
            value = Core.eval(module_, expr)
        end
        return value
    end

    return Core.eval(module_, exprs)
end

function eval_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || return [error_response(request_id, "code must be a string")]

    # Defensive ephemeral fallback: SessionMiddleware normally provides a session
    # before we reach this point.  This guard exists as a safety net for callers
    # that bypass the middleware stack (e.g., direct eval_responses calls in tests
    # or alternative pipelines).  With the default stack it is effectively dead code.
    ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
    session = something(ephemeral, ctx.session)
    module_ = session_module(session)
    stdout_path, stdout_io = mktemp()
    stderr_path, stderr_io = mktemp()

    try
        lock(EVAL_IO_CAPTURE_LOCK)
        try
            value = try
                redirect_stdout(stdout_io) do
                    redirect_stderr(stderr_io) do
                        if isempty(strip(code))
                            nothing
                        else
                            eval_parsed(module_, Meta.parseall(code))
                        end
                    end
                end
            catch ex
                output_messages = buffered_output_messages(
                    request_id,
                    read_captured_output(stdout_io),
                    read_captured_output(stderr_io),
                )
                append!(output_messages, [eval_error_response(request_id, ex; bt=catch_backtrace())])
                return output_messages
            end

            responses = buffered_output_messages(
                request_id,
                read_captured_output(stdout_io),
                read_captured_output(stderr_io),
            )
            push!(responses, response_message(request_id, "value" => safe_repr(value), "ns" => string(nameof(module_))))
            push!(responses, done_response(request_id))
            return responses
        finally
            unlock(EVAL_IO_CAPTURE_LOCK)
        end
    finally
        close(stdout_io)
        close(stderr_io)
        rm(stdout_path; force=true)
        rm(stderr_path; force=true)
        !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
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
    return AbstractMiddleware[SessionMiddleware(), SessionOpsMiddleware(), EvalMiddleware(), UnknownOpMiddleware()]
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
