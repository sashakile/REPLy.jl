struct UnknownOpMiddleware <: AbstractMiddleware end

function handle_message(::UnknownOpMiddleware, msg, next, ctx::RequestContext)
    op = String(get(msg, "op", ""))
    request_id = String(get(msg, "id", ""))
    return [unknown_op_response(request_id, op)]
end
