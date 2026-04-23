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
            "doc"      => "Close a named session by UUID or name alias. Use 'session' field (spec); 'name' is accepted as a deprecated compat alias.",
            "requires" => ["session"],
            "optional" => ["name"],
            "returns"  => String[],
        ),
        "close-session" => Dict{String, Any}(
            "doc"      => "Deprecated alias for 'close'. Close a named session by UUID or name alias.",
            "requires" => ["name"],
            "optional" => String[],
            "returns"  => String[],
        ),
        "clone" => Dict{String, Any}(
            "doc"      => "Clone a named session to a new name. Source is identified by 'session' (spec) or 'source' (compat). Optional 'type' field: 'light' (default) or 'heavy' (post-v1.0, returns not-supported).",
            "requires" => ["name"],
            "optional" => ["session", "source", "type"],
            "returns"  => ["new-session", "name"],
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
    # Session resolution:
    # - Canonical "close" op: accept "session" field (spec) first; fall back to "name" (compat).
    #   When "session" is present, SessionMiddleware has already validated and resolved it
    #   into ctx.session; use the UUID from there to avoid a second lookup.
    # - Deprecated "close-session" op: use only "name" field (existing behavior unchanged).
    if op == "close"
        session_field = get(msg, "session", nothing)
        if !isnothing(session_field)
            # SessionMiddleware has validated and looked up ctx.session for us; use its UUID.
            resolved = ctx.session
            identifier = resolved isa NamedSession ? session_id(resolved) : session_field
            field_used = "session"
        else
            identifier = get(msg, "name", nothing)
            field_used = "name"
        end
    else
        identifier = get(msg, "name", nothing)
        field_used = "name"
    end

    err = validate_session_name(identifier)
    if !isnothing(err)
        return [error_response(request_id, "$(op) \"$(field_used)\": $(err)")]
    end

    session = lookup_named_session(ctx.manager, identifier)
    if isnothing(session)
        return [session_not_found_response(request_id, identifier)]
    end

    # Destroy by UUID to ensure correct removal regardless of input form.
    destroy_named_session!(ctx.manager, session_id(session))
    return [done_response(request_id)]
end

function handle_clone_session(ctx::RequestContext, msg, request_id::AbstractString, op::AbstractString="clone")
    # Source resolution:
    # - Canonical "clone" op: accept "session" field (spec) or "source" field (compat).
    #   When "session" is present, SessionMiddleware has already validated and resolved it
    #   into ctx.session; we extract the UUID from there to avoid a second lookup.
    # - Deprecated "clone-session" op: only accepts "source" field.
    source_str = get(msg, "source", nothing)
    if op == "clone" && isnothing(source_str)
        # Use "session" field if "source" is absent — may already be resolved in ctx.session
        session_field = get(msg, "session", nothing)
        if !isnothing(session_field)
            # SessionMiddleware has validated and looked up ctx.session for us; use its UUID.
            # ctx.session may be Nothing, ModuleSession, or NamedSession — only NamedSession has a UUID.
            resolved = ctx.session
            if resolved isa NamedSession
                source_str = session_id(resolved)
            else
                source_str = session_field
            end
        end
    end

    name = get(msg, "name", nothing)

    src_err = validate_session_name(source_str)
    if !isnothing(src_err)
        return [error_response(request_id, "$(op) \"source\"/\"session\": $(src_err)")]
    end
    name_err = validate_session_name(name)
    if !isnothing(name_err)
        return [error_response(request_id, "$(op) \"name\": $(name_err)")]
    end

    # Type field: only "light" (or absent) is supported; "heavy" is post-v1.0.
    # Any unrecognized type is rejected to keep the contract strict.
    if op == "clone"
        clone_type = get(msg, "type", nothing)
        if clone_type == "heavy"
            return [error_response(request_id, "heavy sessions are post-v1.0";
                        status_flags=String["not-supported"])]
        elseif !isnothing(clone_type) && clone_type != "light"
            return [error_response(request_id, "clone \"type\": unknown value $(repr(clone_type)); accepted values are \"light\" or absent")]
        end
        # "light" or absent is accepted — no action needed.
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
        cloned = clone_named_session!(ctx.manager, source_str, name)
    catch e
        e isa ArgumentError || rethrow(e)
        return [error_response(
            request_id,
            "Session already exists: $(name)";
            status_flags=String["error", "session-already-exists"],
        )]
    end
    if isnothing(cloned)
        return [session_not_found_response(request_id, source_str)]
    end

    cloned_id = session_id(cloned)
    alias = isempty(session_name(cloned)) ? nothing : session_name(cloned)
    # Canonical "clone" returns "new-session" (spec) + "session" (compat).
    # Deprecated "clone-session" returns only "session" per its declared contract.
    pairs = op == "clone" ?
        ("new-session" => cloned_id, "session" => cloned_id, "name" => alias) :
        ("session" => cloned_id, "name" => alias)
    return [response_message(request_id, pairs...), done_response(request_id)]
end
