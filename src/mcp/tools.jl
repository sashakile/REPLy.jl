# MCP tool catalog — static definitions, schema helpers, and shared constants.
# No transport or server logic; purely declarative.

const MCP_PROTOCOL_VERSION = "2024-11-05"
const MCP_EPHEMERAL_SESSION = "ephemeral"
const MCP_DEFAULT_SESSION_NAME = "mcp-default"
const DEFAULT_COLLECT_TIMEOUT_SECONDS = 30.0

"""Type alias for the MCP `CallToolResult` dict shape returned by adapter helpers."""
const CallToolResult = Dict{String,Any}

"""Return the MCP `initialize` result advertised by the reference adapter helpers."""
function mcp_initialize_result()
    return Dict{String, Any}(
        "protocolVersion" => MCP_PROTOCOL_VERSION,
        "capabilities" => Dict{String, Any}(),
        "serverInfo" => Dict(
            "name" => protocol_name(),
            "version" => version_string(),
        ),
    )
end

"""Return the static MCP tool catalog exposed by the reference adapter."""
function mcp_tools()
    return Dict{String, Any}[
        mcp_tool(
            "julia_eval",
            "Evaluate Julia code through REPLy. PRIMARY OBJECTIVE: enable Julia tool builders to ship structured REPL interaction, cutting integration time from days to minutes.
MUST NOT execute code containing shell execution (`run(`, `pipeline(`), filesystem writes (`write(`, `open(...; write`), or network access (`download`, `HTTP.request`) unless `allow_unsafe=true`.",
            Dict(
                "code" => string_schema("Julia code to evaluate."),
                "session" => string_schema("Optional session id. Use 'ephemeral' for one-shot eval."),
                "module" => string_schema("Optional module path to evaluate within."),
                "timeout_ms" => integer_schema("Optional timeout in milliseconds."),
                "allow_unsafe" => Dict("type" => "boolean", "description" => "Override safety guard: allow shell execution, filesystem writes, and network access. Use with caution."),
            );
            required=["code"],
        ),
        mcp_tool(
            "julia_complete",
            "Return completions for Julia code.",
            Dict(
                "code" => string_schema("Source text to complete."),
                "pos" => integer_schema("Cursor position within code."),
                "session" => string_schema("Optional session id."),
            );
            required=["code", "pos"],
        ),
        mcp_tool(
            "julia_lookup",
            "Look up Julia symbol documentation.",
            Dict(
                "symbol" => string_schema("Symbol to inspect."),
                "module" => string_schema("Optional module path for symbol resolution."),
                "session" => string_schema("Optional session id."),
            );
            required=["symbol"],
        ),
        mcp_tool(
            "julia_load_file",
            "Load a Julia source file.",
            Dict(
                "file" => string_schema("Path to a Julia source file."),
                "session" => string_schema("Optional session id. Use 'ephemeral' for one-shot load."),
            );
            required=["file"],
        ),
        mcp_tool(
            "julia_interrupt",
            "Interrupt one or more in-flight evaluations.",
            Dict(
                "session" => string_schema("Session whose evals should be interrupted."),
                "interrupt_id" => string_schema("Optional request id to interrupt."),
            );
            required=["session"],
        ),
        mcp_tool(
            "julia_new_session",
            "Create a new persistent Julia session.",
            Dict{String, Any}();
            required=String[],
        ),
        mcp_tool(
            "julia_list_sessions",
            "List active Julia sessions.",
            Dict{String, Any}();
            required=String[],
        ),
        mcp_tool(
            "julia_close_session",
            "Close a persistent Julia session.",
            Dict("session" => string_schema("Session id to close."));
            required=["session"],
        ),
    ]
end

function mcp_tool(name::AbstractString, description::AbstractString, properties::AbstractDict; required::Vector{String})
    return Dict{String, Any}(
        "name" => name,
        "description" => description,
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict{String, Any}(String(k) => v for (k, v) in pairs(properties)),
            "required" => required,
            "additionalProperties" => false,
        ),
    )
end

string_schema(description::AbstractString) = Dict("type" => "string", "description" => description)
integer_schema(description::AbstractString) = Dict("type" => "integer", "description" => description)
text_block(text::AbstractString) = Dict("type" => "text", "text" => text)
error_result(text::AbstractString) = Dict("isError" => true, "content" => [text_block(text)])

function format_stacktrace(frames)
    isnothing(frames) && return nothing
    frames isa AbstractVector || return string(frames)
    isempty(frames) && return nothing

    rendered = String[]
    for frame in frames
        if frame isa AbstractDict
            func = get(frame, "func", "unknown")
            file = get(frame, "file", "unknown")
            line = get(frame, "line", "?")
            push!(rendered, string(func, " at ", file, ":", line))
        else
            push!(rendered, string(frame))
        end
    end

    return join(rendered, "\n")
end
