"""
    SessionOpsMiddleware

Handle session management operations: `new-session`, `ls-sessions`,
`close-session`/`close`, and `clone-session`/`clone`. These ops manipulate the
named-session registry directly and never delegate to downstream middleware.

The canonical op names (per OpenSpec protocol) are `"close"` and `"clone"`.
The hyphenated forms `"close-session"` and `"clone-session"` are deprecated
aliases kept for backward compatibility — they emit a deprecation warning when
used.

This middleware must appear *after* `SessionMiddleware` in the stack so that
requests carrying a `"session"` key for named-session routing are resolved
first, and *before* `UnknownOpMiddleware` so these ops are not rejected.
"""
struct SessionOpsMiddleware <: AbstractMiddleware end

descriptor(::SessionOpsMiddleware) = MiddlewareDescriptor(
    provides = Set(["new-session", "ls-sessions", "close-session", "clone-session", "close", "clone"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware", "must appear before UnknownOpMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "new-session" => Dict{String, Any}(
            "doc"      => "Create a new named session. Returns a UUID and optional name alias.",
            "requires" => String[],
            "optional" => ["name"],
            "returns"  => ["session", "name"],
        ),
        "ls-sessions" => Dict{String, Any}(
            "doc"      => "List all active named sessions.",
            "requires" => String[],
            "optional" => String[],
            "returns"  => ["sessions"],
        ),
        "close" => Dict{String, Any}(
            "doc"      => "Close a named session by UUID or name alias.",
            "requires" => ["name"],
            "optional" => String[],
            "returns"  => String[],
        ),
        "close-session" => Dict{String, Any}(
            "doc"      => "Deprecated alias for 'close'. Close a named session by UUID or name alias.",
            "requires" => ["name"],
            "optional" => String[],
            "returns"  => String[],
        ),
        "clone" => Dict{String, Any}(
            "doc"      => "Clone a named session to a new name.",
            "requires" => ["source", "name"],
            "optional" => String[],
            "returns"  => ["session", "name"],
        ),
        "clone-session" => Dict{String, Any}(
            "doc"      => "Deprecated alias for 'clone'. Clone a named session to a new name.",
            "requires" => ["source", "name"],
            "optional" => String[],
            "returns"  => ["session", "name"],
        ),
    ),
)

const _SESSION_OPS = ("new-session", "ls-sessions", "close", "close-session", "clone", "clone-session")

function handle_message(::SessionOpsMiddleware, msg, next, ctx::RequestContext)
    op = get(msg, "op", nothing)
    op in _SESSION_OPS || return next(msg)

    request_id = String(get(msg, "id", ""))

    if op == "new-session"
        return handle_new_session(ctx, msg, request_id)
    elseif op == "ls-sessions"
        return handle_ls_sessions(ctx, request_id)
    elseif op == "close"
        return handle_close_session(ctx, msg, request_id, op)
    elseif op == "close-session"
        @warn "op=\"close-session\" is deprecated; use op=\"close\" instead"
        return handle_close_session(ctx, msg, request_id, op)
    elseif op == "clone"
        return handle_clone_session(ctx, msg, request_id, op)
    elseif op == "clone-session"
        @warn "op=\"clone-session\" is deprecated; use op=\"clone\" instead"
        return handle_clone_session(ctx, msg, request_id, op)
    end
end

function handle_new_session(ctx::RequestContext, msg, request_id::AbstractString)
    name = get(msg, "name", nothing)

    # Validate the alias name if provided.
    if !isnothing(name)
        err = validate_session_name(name)
        if !isnothing(err)
            return [error_response(request_id, "new-session \"name\": $(err)")]
        end
    end

    # Enforce server-wide session limit before creating a new named session.
    if !isnothing(ctx.server_state) &&
            total_session_count(ctx.manager) >= ctx.server_state.limits.max_sessions
        return [error_response(request_id, "Session limit reached";
                    status_flags=String["error", "session-limit-reached"])]
    end

    alias = isnothing(name) ? "" : String(name)
    session = create_named_session!(ctx.manager, alias)

    return [
        response_message(request_id,
            "session" => session_id(session),
            "name"    => isempty(alias) ? nothing : alias,
        ),
        done_response(request_id),
    ]
end

function handle_ls_sessions(ctx::RequestContext, request_id::AbstractString)
    sessions = list_named_sessions(ctx.manager)
    session_list = [
        Dict{String, Any}(
            "session"    => session_id(s),
            "name"       => isempty(session_name(s)) ? nothing : session_name(s),
            "created-at" => session_created_at(s),
        )
        for s in sessions
    ]
    return [
        response_message(request_id, "sessions" => session_list),
        done_response(request_id),
    ]
end

function handle_close_session(ctx::RequestContext, msg, request_id::AbstractString, op::AbstractString="close")
    name = get(msg, "name", nothing)
    err = validate_session_name(name)
    if !isnothing(err)
        return [error_response(request_id, "$(op) \"name\": $(err)")]
    end

    session = lookup_named_session(ctx.manager, name)
    if isnothing(session)
        return [session_not_found_response(request_id, name)]
    end

    # Destroy by UUID to ensure correct removal regardless of input form.
    destroy_named_session!(ctx.manager, session_id(session))
    return [done_response(request_id)]
end

function handle_clone_session(ctx::RequestContext, msg, request_id::AbstractString, op::AbstractString="clone")
    source = get(msg, "source", nothing)
    name = get(msg, "name", nothing)

    src_err = validate_session_name(source)
    if !isnothing(src_err)
        return [error_response(request_id, "$(op) \"source\": $(src_err)")]
    end
    name_err = validate_session_name(name)
    if !isnothing(name_err)
        return [error_response(request_id, "$(op) \"name\": $(name_err)")]
    end

    # Enforce server-wide session limit before creating a new named session
    if !isnothing(ctx.server_state) &&
            total_session_count(ctx.manager) >= ctx.server_state.limits.max_sessions
        return [error_response(request_id, "Session limit reached";
                    status_flags=String["error", "session-limit-reached"])]
    end

    # Check if destination already exists before attempting clone
    if !isnothing(lookup_named_session(ctx.manager, name))
        return [error_response(
            request_id,
            "Session already exists: $(name)";
            status_flags=String["error", "session-already-exists"],
        )]
    end

    local cloned
    try
        cloned = clone_named_session!(ctx.manager, source, name)
    catch e
        e isa ArgumentError || rethrow(e)
        return [error_response(
            request_id,
            "Session already exists: $(name)";
            status_flags=String["error", "session-already-exists"],
        )]
    end
    if isnothing(cloned)
        return [session_not_found_response(request_id, source)]
    end

    return [
        response_message(request_id,
            "session" => session_id(cloned),
            "name"    => isempty(session_name(cloned)) ? nothing : session_name(cloned),
        ),
        done_response(request_id),
    ]
end
