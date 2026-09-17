struct UnknownOpMiddleware <: AbstractMiddleware end

descriptor(::UnknownOpMiddleware) = MiddlewareDescriptor(
    provides = Set(["unknown-op"]),
    # Positional "must appear last as the final catch-all" is not forward-expressible;
    # middlewares placed after it would be unreachable. Positional constraints are
    # documented here and in the stack-order spec, not encoded in expects.
    expects  = Set{String}(),
)

function handle_message(::UnknownOpMiddleware, msg, next, ctx::RequestContext)
    op = String(get(msg, "op", ""))
    request_id = String(get(msg, "id", ""))
    return [unknown_op_response(request_id, op)]
end
