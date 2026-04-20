struct SessionMiddleware <: AbstractMiddleware end

function handle_message(::SessionMiddleware, msg, next, ctx::RequestContext)
    op = get(msg, "op", nothing)
    session_id = get(msg, "session", nothing)

    # Named session routing is intentionally op-agnostic: any request carrying a
    # "session" key gets resolved here, regardless of op.  This lets non-eval ops
    # (e.g., completions, inspection) target a specific session.  If the session
    # doesn't exist the caller receives a session-not-found error immediately.
    if session_id isa AbstractString
        request_id = String(get(msg, "id", ""))
        named = lookup_named_session(ctx.manager, session_id)
        if isnothing(named)
            return session_not_found_response(request_id, session_id)
        end
        ctx.session = named
        return next(msg)
    end

    # Ephemeral fallback: only for eval ops without existing session
    if op != "eval" || !isnothing(ctx.session)
        return next(msg)
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
