# MCP request builders — translate MCP tool arguments into Reply protocol requests.
# Stateless: no side effects, never touch sessions or transport.

"""
Build a Reply `eval` request from MCP `julia_eval` arguments.

When `session` is omitted, the adapter routes to `default_session`.
When `session == "ephemeral"`, the Reply request omits the `session` field.
This helper rejects invalid adapter inputs before emitting a Reply message.
"""
function mcp_eval_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    code = get(args, "code", nothing)
    code isa AbstractString || throw(ArgumentError("julia_eval requires a string code field"))

    request = Dict{String, Any}(
        "op" => "eval",
        "id" => request_id,
        "code" => code,
        "allow-stdin" => false,
    )

    session = get(args, "session", default_session)
    if session isa AbstractString
        if session != MCP_EPHEMERAL_SESSION
            request["session"] = session
        end
    elseif !isnothing(session)
        throw(ArgumentError("session must be a string when provided"))
    end

    module_name = get(args, "module", nothing)
    if !isnothing(module_name)
        throw(ArgumentError("module field is not yet supported (CORR-005)"))
    end

    timeout_ms = get(args, "timeout_ms", nothing)
    if !isnothing(timeout_ms)
        throw(ArgumentError("timeout_ms field is not yet supported (CORR-005)"))
    end

    return request
end

"""Build a Reply `complete` request from MCP `julia_complete` arguments."""
function mcp_complete_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    code = get(args, "code", nothing)
    code isa AbstractString || throw(ArgumentError("julia_complete requires a string code field"))
    pos = get(args, "pos", nothing)
    pos isa Integer || throw(ArgumentError("julia_complete requires an integer pos field"))
    return Dict{String, Any}(
        "op" => "complete", "id" => request_id,
        "code" => code, "pos" => pos,
        "session" => mcp_resolve_session(args, default_session),
    )
end

"""Build a Reply `lookup` request from MCP `julia_lookup` arguments."""
function mcp_lookup_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    symbol = get(args, "symbol", nothing)
    symbol isa AbstractString || throw(ArgumentError("julia_lookup requires a string symbol field"))
    request = Dict{String, Any}(
        "op" => "lookup", "id" => request_id,
        "symbol" => symbol,
        "session" => mcp_resolve_session(args, default_session),
    )
    module_name = get(args, "module", nothing)
    if !isnothing(module_name)
        module_name isa AbstractString || throw(ArgumentError("module must be a string when provided"))
        request["module"] = module_name
    end
    return request
end

"""Build a Reply `load-file` request from MCP `julia_load_file` arguments."""
function mcp_load_file_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    file = get(args, "file", nothing)
    file isa AbstractString || throw(ArgumentError("julia_load_file requires a string file field"))
    request = Dict{String, Any}("op" => "load-file", "id" => request_id, "file" => file)
    session = get(args, "session", default_session)
    if session isa AbstractString
        session != MCP_EPHEMERAL_SESSION && (request["session"] = session)
    elseif !isnothing(session)
        throw(ArgumentError("session must be a string when provided"))
    end
    return request
end

"""Build a Reply `interrupt` request from MCP `julia_interrupt` arguments."""
function mcp_interrupt_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    session = get(args, "session", nothing)
    session isa AbstractString || throw(ArgumentError("julia_interrupt requires a string session field"))
    isempty(session) && throw(ArgumentError("julia_interrupt requires a non-empty session field"))
    request = Dict{String, Any}("op" => "interrupt", "id" => request_id, "session" => session)
    interrupt_id = get(args, "interrupt_id", nothing)
    if !isnothing(interrupt_id)
        parsed = interrupt_id isa Integer ? Int(interrupt_id) : tryparse(Int, string(interrupt_id))
        isnothing(parsed) && throw(ArgumentError("interrupt_id must be an integer"))
        request["interrupt-id"] = parsed
    end
    return request
end

# Resolve an MCP session argument to a Reply session name that is guaranteed to
# exist: falls back to `default_session` when omitted or when "ephemeral" is
# requested (introspection ops like complete/lookup need a real session module).
function mcp_resolve_session(args, default_session)
    session = get(args, "session", default_session)
    session isa AbstractString || throw(ArgumentError("session must be a string when provided"))
    return session == MCP_EPHEMERAL_SESSION ? default_session : session
end
