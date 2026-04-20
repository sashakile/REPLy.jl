"""
    SessionOpsMiddleware

Handle session management operations: `ls-sessions`, `close-session`, and
`clone-session`. These ops manipulate the named-session registry directly
and never delegate to downstream middleware.

This middleware must appear *after* `SessionMiddleware` in the stack so that
requests carrying a `"session"` key for named-session routing are resolved
first, and *before* `UnknownOpMiddleware` so these ops are not rejected.
"""
struct SessionOpsMiddleware <: AbstractMiddleware end

function handle_message(::SessionOpsMiddleware, msg, next, ctx::RequestContext)
    op = get(msg, "op", nothing)
    op in ("ls-sessions", "close-session", "clone-session") || return next(msg)

    request_id = String(get(msg, "id", ""))

    if op == "ls-sessions"
        return handle_ls_sessions(ctx, request_id)
    elseif op == "close-session"
        return handle_close_session(ctx, msg, request_id)
    elseif op == "clone-session"
        return handle_clone_session(ctx, msg, request_id)
    end
end

function handle_ls_sessions(ctx::RequestContext, request_id::AbstractString)
    sessions = list_named_sessions(ctx.manager)
    session_list = [
        Dict{String, Any}(
            "name" => session_name(s),
            "created-at" => session_created_at(s),
        )
        for s in sessions
    ]
    return [
        response_message(request_id, "sessions" => session_list),
        done_response(request_id),
    ]
end

function handle_close_session(ctx::RequestContext, msg, request_id::AbstractString)
    name = get(msg, "name", nothing)
    if !isa(name, AbstractString) || isempty(name)
        return [error_response(request_id, "close-session requires a non-empty \"name\" parameter")]
    end

    session = lookup_named_session(ctx.manager, name)
    if isnothing(session)
        return [session_not_found_response(request_id, name)]
    end

    destroy_named_session!(ctx.manager, name)
    return [done_response(request_id)]
end

function handle_clone_session(ctx::RequestContext, msg, request_id::AbstractString)
    source = get(msg, "source", nothing)
    name = get(msg, "name", nothing)

    if !isa(source, AbstractString) || isempty(source)
        return [error_response(request_id, "clone-session requires a non-empty \"source\" parameter")]
    end
    if !isa(name, AbstractString) || isempty(name)
        return [error_response(request_id, "clone-session requires a non-empty \"name\" parameter")]
    end

    # Check if destination already exists before attempting clone
    if !isnothing(lookup_named_session(ctx.manager, name))
        return [error_response(
            request_id,
            "Session already exists: $(name)";
            status_flags=String["error", "session-already-exists"],
        )]
    end

    cloned = clone_named_session!(ctx.manager, source, name)
    if isnothing(cloned)
        return [session_not_found_response(request_id, source)]
    end

    return [
        response_message(request_id, "name" => session_name(cloned)),
        done_response(request_id),
    ]
end
