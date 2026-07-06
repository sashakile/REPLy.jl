# Ping middleware — handles `op == "ping"` as a lightweight liveness probe.
# Returns `{"status":["done","pong"]}` without touching any session or running
# an eval, so process managers and agents can detect readiness cheaply.

"""
    PingMiddleware

Middleware that answers `op == "ping"` with a single terminal
`{"status":["done","pong"]}` response. No session is looked up or created and
no code is evaluated, making it a cheap liveness/readiness probe.

All other ops are forwarded to the next middleware.
"""
struct PingMiddleware <: AbstractMiddleware end

descriptor(::PingMiddleware) = MiddlewareDescriptor(
    provides = Set(["ping"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "ping" => Dict{String, Any}(
            "doc"      => "Lightweight liveness probe. Returns status [done, pong] without starting a session or running an eval.",
            "requires" => String[],
            "optional" => String[],
            "returns"  => String[],
        ),
    ),
)

function handle_message(::PingMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "ping" || return next(msg)
    request_id = String(get(msg, "id", ""))
    return [response_message(request_id, "status" => ["done", "pong"])]
end
