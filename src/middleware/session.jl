struct SessionMiddleware <: AbstractMiddleware end

function handle_message(::SessionMiddleware, msg, next, ctx::RequestContext)
    if get(msg, "op", nothing) != "eval" || !isnothing(ctx.session)
        return next(msg)
    end

    session = create_ephemeral_session!(ctx.manager)
    ctx.session = session
    try
        return next(msg)
    finally
        destroy_session!(ctx.manager, session)
        ctx.session = nothing
    end
end
