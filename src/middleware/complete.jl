# Complete middleware — handles `op == "complete"` requests and returns tab-completion
# candidates at the given cursor position using Julia's REPL completion engine.

"""
    CompleteMiddleware

Middleware that handles `op == "complete"` requests. Uses Julia's built-in REPL
completion engine to return candidates at the given cursor position. Out-of-range
positions return an empty completions array rather than an error. All other ops
are forwarded to the next middleware.
"""
struct CompleteMiddleware <: AbstractMiddleware end

function handle_message(::CompleteMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "complete" || return next(msg)
    return complete_responses(ctx, msg)
end

function complete_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])

    code = get(request, "code", nothing)
    code isa AbstractString || return [error_response(request_id, "complete requires a string code field")]

    pos = get(request, "pos", nothing)
    pos isa Integer || return [error_response(request_id, "complete requires an integer pos field")]

    session_mod = isnothing(ctx.session) ? Main : session_module(ctx.session)
    completions = _get_completions(code, Int(pos), session_mod)

    return [
        response_message(request_id, "completions" => completions),
        done_response(request_id),
    ]
end

function _get_completions(code::AbstractString, pos::Int, module_::Module)
    # REQ-RPL-015b: out-of-bounds pos returns empty completions, not an error.
    (pos < 0 || pos > ncodeunits(code)) && return Dict{String, Any}[]

    raw, _, _ = try
        REPL.REPLCompletions.completions(code, pos, module_)
    catch
        return Dict{String, Any}[]
    end

    return [
        Dict{String, Any}(
            "text" => REPL.REPLCompletions.completion_text(c),
            "type" => _completion_type_name(c),
        )
        for c in raw
    ]
end

_completion_type_name(c) = replace(string(typeof(c)), r"^.*\." => "")
