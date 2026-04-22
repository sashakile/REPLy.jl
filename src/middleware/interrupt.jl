# Interrupt middleware — handles `op == "interrupt"` requests by throwing
# InterruptException to the eval task running in the target session.
# Returns the session name in the `interrupted` array when an eval was active,
# or an empty array when idempotent (no running eval).

"""
    InterruptMiddleware

Middleware that handles `op == "interrupt"` requests. Looks up the named session
specified by the `session` field, throws `InterruptException` to the eval task
if one is running, and returns an `interrupted` array in the response.

- Running eval: `interrupted` contains the session name; the eval task receives
  `InterruptException` and will terminate with `status:["done","interrupted"]`.
- Idle or already-completed session: `interrupted` is empty (idempotent).

All other ops are forwarded to the next middleware.
"""
struct InterruptMiddleware <: AbstractMiddleware end

function handle_message(::InterruptMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "interrupt" || return next(msg)
    return interrupt_responses(ctx, msg)
end

function interrupt_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])

    session_name = get(request, "session", nothing)
    if !(session_name isa AbstractString) || isempty(session_name)
        return [error_response(request_id, "interrupt requires a non-empty string session field")]
    end

    session = lookup_named_session(ctx.manager, String(session_name))
    if isnothing(session)
        return [session_not_found_response(request_id, String(session_name))]
    end

    interrupted = _interrupt_session_eval(session)

    return [
        response_message(request_id, "interrupted" => interrupted),
        done_response(request_id),
    ]
end

function _interrupt_session_eval(session::NamedSession)
    task = lock(session.lock) do
        session.state === SessionRunning ? session.eval_task : nothing
    end

    isnothing(task) && return String[]

    try
        schedule(task, InterruptException(); error=true)
    catch
        # schedule can fail if the task has already completed; treat as idempotent.
        return String[]
    end

    return [session.name]
end
