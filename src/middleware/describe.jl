# Describe middleware — handles `op == "describe"` requests and returns a dynamic
# snapshot of server capabilities built from middleware descriptors: ops catalog,
# versions, and encoding support.

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
            "returns"  => ["ops", "versions", "encodings-available", "encoding-current"],
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
        "status" => ["done"],
    )]
end
