"""
    AuditMiddleware(log; client_id, source_ip)

Middleware that records every request to an `AuditLog`. Place it first in the
stack so all operations (eval, session ops, describe, etc.) are captured.

`client_id` and `source_ip` are per-connection identifiers; they default to a
nil UUID and an empty string. Pass them explicitly when per-connection identity
is available (e.g. from the transport layer).
"""
struct AuditMiddleware <: AbstractMiddleware
    log::AuditLog
    client_id::UUID
    source_ip::String
end

AuditMiddleware(log::AuditLog; client_id::UUID=UUID(UInt128(0)), source_ip::AbstractString="") =
    AuditMiddleware(log, client_id, String(source_ip))

function handle_message(mw::AuditMiddleware, msg, next, ctx::RequestContext)
    op = String(get(msg, "op", ""))
    t = now(UTC)
    try
        result = next(msg)
        sid = ctx.session isa NamedSession ? session_id(ctx.session) : nothing
        record_audit!(mw.log, AuditLogEntry(
            timestamp=t,
            client_id=mw.client_id,
            session_id=sid,
            operation=op,
            source_ip=mw.source_ip,
            success=true,
        ))
        return result
    catch ex
        sid = ctx.session isa NamedSession ? session_id(ctx.session) : nothing
        record_audit!(mw.log, AuditLogEntry(
            timestamp=t,
            client_id=mw.client_id,
            session_id=sid,
            operation=op,
            source_ip=mw.source_ip,
            success=false,
            error=sprint(showerror, ex),
        ))
        rethrow()
    end
end
