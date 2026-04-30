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

descriptor(::InterruptMiddleware) = MiddlewareDescriptor(
    provides = Set(["interrupt"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "interrupt" => Dict{String, Any}(
            "doc"      => "Interrupt an in-flight evaluation.",
            "requires" => ["session"],
            "optional" => ["interrupt-id"],
            "returns"  => ["interrupted", "interrupted-id"],
        ),
    ),
)

function handle_message(::InterruptMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "interrupt" || return next(msg)
    return interrupt_responses(ctx, msg)
end

function interrupt_responses(ctx::RequestContext, request::AbstractDict)
    request_id = String(request["id"])

    session = ctx.session
    if !(session isa NamedSession)
        session_name = get(request, "session", nothing)
        if !(session_name isa AbstractString) || isempty(session_name)
            return [error_response(request_id, "interrupt requires a non-empty string session field")]
        end
        session = lookup_named_session(ctx.manager, String(session_name))
        if isnothing(session)
            return [session_not_found_response(request_id, String(session_name))]
        end
    end

    interrupt_id = get(request, "interrupt-id", nothing)
    interrupted, interrupted_id = _interrupt_session_eval(session; interrupt_id=interrupt_id)

    return [
        response_message(request_id, "interrupted" => interrupted, "interrupted-id" => interrupted_id),
        done_response(request_id),
    ]
end

"""
    _interrupt_session_eval(session; interrupt_id=nothing) -> (interrupted, interrupted_id)

Attempt to interrupt the running eval in `session`.

- `interrupt_id`: if provided (non-nothing), only interrupt when the running eval's
  ID matches. If there is a mismatch (the targeted eval already finished), returns
  no-op success `([], nothing)`.
- Returns `(interrupted::Vector{String}, interrupted_id::Union{Int,Nothing})` where
  `interrupted` contains `session.name` on a real interrupt and `interrupted_id` holds
  the eval ID that was interrupted (or `nothing` when no interrupt was sent).
"""
function _interrupt_session_eval(session::NamedSession; interrupt_id::Union{Integer,Nothing}=nothing)
    task, current_eval_id = lock(session.lock) do
        if session.state === SessionRunning
            (session.eval_task, session.eval_id)
        else
            (nothing, session.eval_id)
        end
    end

    isnothing(task) && return (String[], nothing)

    # If a specific interrupt-id was requested, check it matches the running eval.
    if !isnothing(interrupt_id) && current_eval_id != interrupt_id
        return (String[], nothing)
    end

    try
        schedule(task, InterruptException(); error=true)
    catch
        # schedule can fail if the task has already completed; treat as idempotent.
        return (String[], nothing)
    end

    return ([session.name], current_eval_id)
end
