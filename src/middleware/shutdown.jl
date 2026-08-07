# Shutdown middleware — handles `op == "shutdown"` to trigger graceful server
# shutdown. The server handle is registered via a module-level callback so the
# middleware can close it without needing a direct reference.

"""
    ShutdownMiddleware

Middleware that handles `op == "shutdown"` requests. Triggers graceful shutdown
of the server via the global shutdown callback mechanism established by
`serve()` and `serve_multi()`.

The shutdown is scheduled asynchronously so the response is sent before the
server closes the client connection. All other ops are forwarded.

# Security note
Any client that can reach the server can trigger shutdown. In environments that
require access control, pair this middleware with network-level restrictions
(firewall, VPN) or use Unix domain sockets with owner-only permissions.
"""
struct ShutdownMiddleware <: AbstractMiddleware end

descriptor(::ShutdownMiddleware) = MiddlewareDescriptor(
    provides = Set(["shutdown"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "shutdown" => Dict{String, Any}(
            "doc"      => "Gracefully shut down the server. Closes all listeners, drains clients, interrupts active evals, and cleans up OS resources.",
            "requires" => String[],
            "optional" => String[],
            "returns"  => String[],
        ),
    ),
)

function handle_message(::ShutdownMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "shutdown" || return next(msg)
    request_id = String(get(msg, "id", ""))
    # Set the shutdown flag on the server state. The handle_client! loop will
    # detect this flag after the response is sent and trigger the synchronous
    # shutdown callback. This ensures the response reaches the client before
    # the server closes the connection.
    if !isnothing(ctx.server_state)
        for life in begin_shutdown!(ctx.server_state::ServerState)
            request_eval_cancel!(life)
        end
    end
    return [Dict{String, Any}(
        "id" => request_id,
        "status" => ["done", "shutdown-started"],
    )]
end
