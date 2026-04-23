# Describe middleware — handles `op == "describe"` requests and returns a static
# snapshot of server capabilities: ops catalog, versions, and encoding support.

"""Static catalog of all built-in ops advertised by the describe operation."""
const DESCRIBE_OPS_CATALOG = Dict{String, Any}(
    "describe" => Dict{String, Any}(
        "doc" => "Return server capabilities: ops, versions, and encodings.",
        "requires" => String[],
        "optional" => String[],
        "returns" => ["ops", "versions", "encodings-available", "encoding-current"],
    ),
    "eval" => Dict{String, Any}(
        "doc" => "Evaluate Julia code in a session module.",
        "requires" => ["code"],
        "optional" => ["session", "module", "timeout-ms", "allow-stdin", "silent", "store-history"],
        "returns" => ["out", "err", "value", "ns"],
    ),
    "load-file" => Dict{String, Any}(
        "doc" => "Load and evaluate a Julia source file.",
        "requires" => ["file"],
        "optional" => ["session"],
        "returns" => ["out", "err", "value", "ns"],
    ),
    "interrupt" => Dict{String, Any}(
        "doc" => "Interrupt an in-flight evaluation.",
        "requires" => ["session"],
        "optional" => ["interrupt-id"],
        "returns" => ["interrupted"],
    ),
    "complete" => Dict{String, Any}(
        "doc" => "Return tab-completions for Julia code.",
        "requires" => ["code", "pos"],
        "optional" => ["session"],
        "returns" => ["completions"],
    ),
    "lookup" => Dict{String, Any}(
        "doc" => "Look up Julia symbol documentation.",
        "requires" => ["symbol"],
        "optional" => ["session", "module"],
        "returns" => ["doc"],
    ),
    "stdin" => Dict{String, Any}(
        "doc" => "Send input to a running eval waiting on stdin.",
        "requires" => ["session", "input"],
        "optional" => String[],
        "returns" => String[],
    ),
    "ls-sessions" => Dict{String, Any}(
        "doc" => "List all active named sessions.",
        "requires" => String[],
        "optional" => String[],
        "returns" => ["sessions"],
    ),
    "close-session" => Dict{String, Any}(
        "doc" => "Close a named session by name.",
        "requires" => ["name"],
        "optional" => String[],
        "returns" => String[],
    ),
    "clone-session" => Dict{String, Any}(
        "doc" => "Clone a named session to a new name.",
        "requires" => ["source", "name"],
        "optional" => String[],
        "returns" => ["name"],
    ),
)

"""
    DescribeMiddleware

Middleware that handles `op == "describe"` requests. Returns a single terminal
response containing the static ops catalog, Julia and Reply versions, and
encoding support. All other ops are forwarded to the next middleware.
"""
struct DescribeMiddleware <: AbstractMiddleware end

descriptor(::DescribeMiddleware) = MiddlewareDescriptor(
    provides = Set(["describe"]),
)

function handle_message(::DescribeMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "describe" || return next(msg)
    request_id = String(get(msg, "id", ""))
    return [Dict{String, Any}(
        "id" => request_id,
        "ops" => DESCRIBE_OPS_CATALOG,
        "versions" => Dict{String, Any}(
            "julia" => string(VERSION),
            "reply" => version_string(),
        ),
        "encodings-available" => ["json"],
        "encoding-current" => "json",
        "status" => ["done"],
    )]
end
