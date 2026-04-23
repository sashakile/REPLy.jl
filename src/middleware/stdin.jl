# Stdin middleware — handles `op == "stdin"` requests by delivering text input
# to the target session's stdin channel. If the session has a running eval blocked
# on stdin, the input is forwarded to the eval via a per-eval Pipe; otherwise it
# is buffered in the session's Channel{String} for the next eval.

"""
    StdinMiddleware

Middleware that handles `op == "stdin"` requests. Puts `input` text into the
named session's `stdin_channel`, where a per-eval feeder task picks it up and
writes it to the eval's redirected `stdin` pipe.

- Running eval (SessionRunning): `delivered` contains the session name.
- Idle session (SessionIdle): `buffered` contains the session name; input waits
  in the channel for the next eval's feeder to consume.
- Closed or unknown session: returns an error response.

All other ops are forwarded to the next middleware.
"""
struct StdinMiddleware <: AbstractMiddleware end

descriptor(::StdinMiddleware) = MiddlewareDescriptor(
    provides = Set(["stdin"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware"],
)

function handle_message(::StdinMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "stdin" || return next(msg)
    return stdin_responses(ctx, msg)
end

function stdin_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])

    session_name = get(request, "session", nothing)
    if !(session_name isa AbstractString) || isempty(session_name)
        return [error_response(request_id, "stdin requires a non-empty string session field")]
    end

    input = get(request, "input", nothing)
    if !(input isa AbstractString)
        return [error_response(request_id, "stdin requires a string input field")]
    end

    session = lookup_named_session(ctx.manager, String(session_name))
    if isnothing(session)
        return [session_not_found_response(request_id, String(session_name))]
    end

    # Snapshot state under lock; put! outside the lock (Channel is thread-safe).
    state = lock(session.lock) do; session.state; end

    state === SessionClosed && return [error_response(request_id, "session is closed: $(session_name)")]

    put!(session.stdin_channel, String(input))
    field = state === SessionRunning ? "delivered" : "buffered"

    return [
        response_message(request_id, field => [session.name]),
        done_response(request_id),
    ]
end
