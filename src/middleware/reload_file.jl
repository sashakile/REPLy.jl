# Reload-file middleware — handles `op == "reload-file"`. Clears the stale
# top-level module binding for a file (if it defines one) before re-including it,
# then forwards to `load-file`. This covers the common hot-reload cycle: editing a
# file that defines `module Foo` and re-including it would otherwise leave two Foo
# bindings, making a later `using .Foo` fail with an ambiguity error.
#
# ReloadFileMiddleware MUST be placed before LoadFileMiddleware in the stack so the
# forwarded `load-file` request reaches LoadFileMiddleware.

const _MODULE_DECL_PATTERN = r"^\s*(?:bare)?module\s+([A-Za-z_]\w*)"m

"""
    ReloadFileMiddleware(; load_file_allowlist=nothing)
    ReloadFileMiddleware(limits::ResourceLimits; load_file_allowlist=nothing)

Middleware that handles `op == "reload-file"`. Requires an existing named session
(via the `session` field) and a `file` field. If the file's first top-level
declaration is `module Foo` / `baremodule Foo`, the stale `Foo` binding in the
session module is deleted before re-including, so a subsequent `using .Foo` is
unambiguous. The request is then forwarded to `load-file`, reusing its file I/O,
allowlist, eval, and output-capture machinery.

`load_file_allowlist` mirrors `LoadFileMiddleware`: it must be a function
`(path::String) -> Bool`. When not provided, all reload requests are denied by
default (matching `LoadFileMiddleware`) — the allowlist is checked here too so the
module-detection read never touches a disallowed path.

Note: this only refreshes top-level bindings; it does not resolve world-age
issues with methods already compiled against the previous module.

All other ops are forwarded to the next middleware.
"""
struct ReloadFileMiddleware <: AbstractMiddleware
    load_file_allowlist::Union{Nothing, Function}
end
ReloadFileMiddleware(; load_file_allowlist=nothing) = ReloadFileMiddleware(load_file_allowlist)
ReloadFileMiddleware(::ResourceLimits; load_file_allowlist=nothing) = ReloadFileMiddleware(load_file_allowlist)

descriptor(::ReloadFileMiddleware) = MiddlewareDescriptor(
    provides = Set(["reload-file"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware", "must appear before LoadFileMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "reload-file" => Dict{String, Any}(
            "doc"      => "Re-include a Julia source file into a named session, first clearing the stale top-level module binding it defines so a subsequent 'using .Mod' is unambiguous. Requires an existing named session. Does not fix world-age issues for already-compiled methods.",
            "requires" => ["file", "session"],
            "optional" => String[],
            "returns"  => ["out", "err", "value", "repr-error", "ns"],
        ),
    ),
)

function handle_message(mw::ReloadFileMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "reload-file" || return next(msg)
    request_id = String(get(msg, "id", ""))

    file = get(msg, "file", nothing)
    file isa AbstractString || return [error_response(request_id, "reload-file requires a string file field")]

    session = ctx.session
    session isa NamedSession ||
        return [error_response(request_id, "reload-file requires an existing named session (set the session field)")]

    # Enforce the same allowlist as load-file before any file I/O, so the
    # module-detection read cannot probe disallowed paths.
    if isnothing(mw.load_file_allowlist)
        return [error_response(
            request_id,
            "reload-file requires an explicit allowlist; no files are accessible by default. " *
            "Pass load_file_allowlist = path -> true to allow all paths (insecure).";
            status_flags=String["error", "path-not-allowed"],
        )]
    end
    mw.load_file_allowlist(file) || return [error_response(
        request_id,
        "Path not allowed: $file";
        status_flags=String["error", "path-not-allowed"],
    )]

    code = try
        read(file, String)
    catch ex
        return [error_response(request_id, "Failed to read file: $(safe_showerror(ex))")]
    end

    decl = match(_MODULE_DECL_PATTERN, code)
    if !isnothing(decl)
        sym = Symbol(decl.captures[1])
        mod = session_module(session)
        if isdefined(mod, sym)
            try
                Base.delete_binding(mod, sym)
            catch
                # Best effort: if the binding cannot be deleted, fall through and
                # let the re-include proceed (it may still succeed or surface a
                # clearer error to the caller).
            end
        end
    end

    # Forward as load-file, reusing its I/O capture, allowlist, and eval machinery.
    load_msg = Dict{String, Any}(
        "op"      => "load-file",
        "id"      => request_id,
        "file"    => file,
        "session" => session_id(session),
    )
    return next(load_msg)
end
