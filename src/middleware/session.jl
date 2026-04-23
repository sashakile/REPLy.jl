struct SessionMiddleware <: AbstractMiddleware end

descriptor(::SessionMiddleware) = MiddlewareDescriptor(
    provides = Set(["session"]),
    expects  = ["must appear first in stack to provide named-session routing for downstream middleware"],
)

const MAX_SESSION_NAME_BYTES = 256
const SESSION_NAME_PATTERN = r"^[a-zA-Z0-9_-]+$"

"""
    validate_session_name(name) -> Union{Nothing, String}

Return `nothing` if `name` is a valid session name, or an error message string if not.
Valid names are non-empty, non-whitespace-only, match `[a-zA-Z0-9_-]+`, and are at
most `MAX_SESSION_NAME_BYTES` bytes.
"""
function validate_session_name(name)
    name isa AbstractString || return "session name must be a string"
    isempty(strip(name)) && return "session name must not be blank"
    isnothing(match(SESSION_NAME_PATTERN, name)) && return "session name may only contain letters, digits, hyphens, and underscores"
    ncodeunits(name) > MAX_SESSION_NAME_BYTES && return "session name exceeds maximum length of $(MAX_SESSION_NAME_BYTES)"
    return nothing
end

function handle_message(::SessionMiddleware, msg, next, ctx::RequestContext)
    op = get(msg, "op", nothing)
    session_id = get(msg, "session", nothing)

    # Named session routing is intentionally op-agnostic: any request carrying a
    # "session" key gets resolved here, regardless of op.  This lets non-eval ops
    # (e.g., completions, inspection) target a specific session.  If the session
    # doesn't exist the caller receives a session-not-found error immediately.
    if session_id isa AbstractString
        request_id = String(get(msg, "id", ""))
        err = validate_session_name(session_id)
        if !isnothing(err)
            return [error_response(request_id, err)]
        end
        named = lookup_named_session(ctx.manager, session_id)
        if isnothing(named)
            return [session_not_found_response(request_id, session_id)]
        end
        ctx.session = named
        return next(msg)
    end

    # Ephemeral fallback: only for eval ops without existing session
    if op != "eval" || !isnothing(ctx.session)
        return next(msg)
    end

    if !isnothing(ctx.server_state)
        request_id = String(get(msg, "id", ""))
        if total_session_count(ctx.manager) >= ctx.server_state.limits.max_sessions
            return [error_response(request_id, "Session limit reached";
                        status_flags=String["error", "session-limit-reached"])]
        end
    end

    session = create_ephemeral_session!(ctx.manager)
    ctx.session = session
    try
        return next(msg)
    finally
        destroy_session!(ctx.manager, session)
        ctx.session = nothing
    end
end
