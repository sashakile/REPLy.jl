# Purpose: Describe available operations and attached execution guarantees.
# Responsibilities:
# - Build operation, version and encoding metadata for ordinary describe requests.
# - Report cooperative deadlines and unsupported attached memory enforcement.
# Rationale: REPLy_jl-q8dz.2 makes discovery honest without changing execution ownership.

"""
    DescribeMiddleware(ops_catalog)

Middleware that handles `op == "describe"` requests. Returns a single terminal
response containing the ops catalog (built dynamically from middleware descriptors
by `build_handler`), Julia and Reply versions, and encoding support. All other
ops are forwarded to the next middleware.

Construct with no arguments for an empty catalog (useful in unit tests that only
check top-level fields, versions, or forwarding). Use `build_handler()` to get a
fully populated catalog derived from the active middleware stack.
"""
struct DescribeMiddleware <: AbstractMiddleware
    ops_catalog::Dict{String, Any}
end
DescribeMiddleware() = DescribeMiddleware(Dict{String, Any}())

descriptor(::DescribeMiddleware) = MiddlewareDescriptor(
    provides = Set(["describe"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "describe" => Dict{String, Any}(
            "doc"      => "Return server capabilities: ops, versions, and encodings.",
            "requires" => String[],
            "optional" => String[],
            "returns"  => ["ops", "versions", "encodings-available", "encoding-current",
                "execution-mode", "timeout-enforcement", "memory-enforcement", "effective-memory-limit-mb"],
        ),
    ),
)

function handle_message(mw::DescribeMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "describe" || return next(msg)
    request_id = String(get(msg, "id", ""))
    return [Dict{String, Any}(
        "id" => request_id,
        "ops" => mw.ops_catalog,
        "versions" => Dict{String, Any}(
            "julia" => string(VERSION),
            "reply" => version_string(),
        ),
        "encodings-available" => ["json"],
        "encoding-current" => "json",
        "execution-mode" => "attached",
        "timeout-enforcement" => "cooperative",
        "memory-enforcement" => "unsupported",
        "effective-memory-limit-mb" => 0,
        "status" => ["done"],
    )]
end
