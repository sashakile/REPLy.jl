# Building Custom REPLy Middleware

**TL;DR:** Extend REPLy by implementing `AbstractMiddleware` and overriding
`handle_message`. Three non-negotiable rules apply before your first line of
business logic: annotate `ctx::RequestContext`, understand that `next(msg)`
advances the stack (not restarts it), and place middlewares that forward to
other ops *before* the ops they delegate to.

## Context and Prerequisites

This guide explains how to add new protocol operations, transform requests
transparently, and augment responses in a live REPLy server — without forking
the library.

You should already:

- Have a running REPLy server (`REPLy.serve(port=5555)`)
- Understand the basic wire protocol (`op`, `id`, `session` fields)
- Be comfortable with Julia structs and multiple dispatch

**Working code:** All examples in this guide are tested against Julia 1.12.6 and
REPLy 0.1.0.

## How the Middleware Chain Works

Every inbound request travels through an ordered `Vector{AbstractMiddleware}`.
Each piece can:

- **Intercept** — handle an op and return without calling `next`
- **Transform** — modify the request, call `next`, return the result
- **Augment** — call `next`, inject extra response messages, return

```
Request → [MW 1] → [MW 2] → [MW 3] → ... → [UnknownOpMiddleware]
                    ↑
              your middleware here
```

The chain terminates when a middleware returns without calling `next`, or when
`UnknownOpMiddleware` catches whatever fell through.

### The `handle_message` contract

```julia
function REPLy.handle_message(mw::YourMiddleware, msg, next, ctx::RequestContext)
    # msg  — inbound request (JSON3.Object, read-only)
    # next — fn(msg) → advances to the next middleware
    # ctx  — mutable request context (session, manager, server state)
    ...
end
```

The return value is `Vector{Dict{String,Any}}` — the response message sequence.
Return `next(msg)` to pass through, or return your own response vector to
short-circuit.

## Non-Negotiable Rule 1: Always Annotate `ctx::RequestContext`

This rule has no exceptions. Omitting the type annotation produces a runtime
method ambiguity error on the first request.

REPLy defines a default fallback:

```julia
# REPLy's default — applies to every AbstractMiddleware
handle_message(::AbstractMiddleware, msg, next, ctx::RequestContext) = next(msg)
```

If you write your override without the `ctx` type:

```julia
# WRONG — Julia sees two equally-specific candidates
function REPLy.handle_message(::MyMW, msg, next, ctx)
    ...
end
```

Julia cannot choose between your method and the default. The first request
produces:

```
MethodError: handle_message(...) is ambiguous.
Possible fix, define handle_message(::MyMW, ::Any, ::Any, ::RequestContext)
```

Always write:

```julia
# CORRECT — more specific than the default
function REPLy.handle_message(::MyMW, msg, next, ctx::REPLy.RequestContext)
    ...
end
```

## Non-Negotiable Rule 2: `next(msg)` Advances the Stack, Not Restarts It

`next` is a closure over the current stack position. It calls the *next*
middleware in the vector, not the beginning of the chain.

**Consequence:** If middleware A forwards a request with a different op to be
handled by middleware B, then A must be placed *before* B in the stack.

```
Stack:  [A]  →  [B]  →  [C]  →  [UnknownOp]
                 ↑
         B handles op "load-file"

If A is here:  A calls next({"op":"load-file",...})
               → B receives it  ✓

If A is here:        [B]  →  [A]  →  [C]  →  [UnknownOp]
               A calls next({"op":"load-file",...})
               → C receives it, then UnknownOp  ✗
               → {"err":"Unknown operation: load-file"}
```

This is the most common source of silent failures when building middlewares
that delegate to other ops.

## Non-Negotiable Rule 3: Declare Your Op in the Descriptor

`REPLy.describe` reports advertised ops to clients. If your op is not in the
descriptor, it will not appear in `describe` responses.

```julia
REPLy.descriptor(::MyMW) = REPLy.MiddlewareDescriptor(
    provides = Set(["my-op"]),
    op_info  = Dict("my-op" => Dict{String,Any}(
        "doc"      => "What this op does.",
        "requires" => ["field-a"],
        "optional" => ["field-b"],
        "returns"  => ["result"],
    )),
)
```

`validate_stack(stack)` checks for duplicate `provides` entries and unsatisfied
`requires` dependencies. Call it before starting your server:

```julia
errors = REPLy.validate_stack(stack)
isempty(errors) || (foreach(println, errors); exit(1))
```

## What `RequestContext` Gives You

`ctx::RequestContext` is your window into the server's state for the current
request:

| Field | Type | Use |
|-------|------|-----|
| `ctx.session` | `NamedSession \| ModuleSession \| Nothing` | Active session (set by `SessionMiddleware`) |
| `ctx.manager` | `SessionManager` | Create, look up, destroy sessions |
| `ctx.server_state` | `ServerState \| Nothing` | Resource limits, active eval counter |
| `ctx.emitted` | `Vector{Dict}` | Side-channel messages (written via `emit!`) |

Accessing the session's Julia module:

```julia
mod = REPLy.session_module(ctx.session)  # returns the Module
names(mod; all=true)                     # all bindings in the session
getfield(mod, :my_var)                   # read a specific binding
```

Checking if a session is present:

```julia
isnothing(ctx.session) && return [REPLy.error_response(id, "requires a session")]
```

Note: `ctx.session` is `nothing` for ephemeral evals (no `session` field in the
request) and for ops that don't route through `SessionMiddleware`.

## Injecting Extra Response Messages with `emit!`

`REPLy.emit!(ctx, msg)` pushes a message into `ctx.emitted`. These messages
appear before the terminal response in the final output, regardless of when
`emit!` is called.

```julia
# Call next first, then emit — timing appears before done
function REPLy.handle_message(::TimingMiddleware, msg, next, ctx::REPLy.RequestContext)
    t0 = time_ns()
    result = next(msg)
    elapsed_ms = round((time_ns() - t0) / 1_000_000.0, digits=3)
    id = String(get(msg, "id", ""))
    REPLy.emit!(ctx, Dict{String,Any}("id" => id, "timing-ms" => elapsed_ms))
    return result
end
```

Response the client sees:

```json
{"id":"r1","value":"4"}
{"id":"r1","timing-ms":12.393}
{"id":"r1","status":["done"]}
```

Use `emit!` for: timing data, metrics annotations, deprecation warnings,
progress notifications, debug traces.

## Modifying a Request Before Forwarding

The `msg` parameter is a `JSON3.Object` — immutable. To forward a modified
request, build a new `Dict`:

```julia
function REPLy.handle_message(::IncludeFixMiddleware, msg, next,
                               ctx::REPLy.RequestContext)
    get(msg, "op", "") == "eval" || return next(msg)
    code = get(msg, "code", nothing)
    code isa AbstractString || return next(msg)

    fixed = replace(code, r"(?<![.\w])include\(" => "Base.include(@__MODULE__, ")
    fixed == code && return next(msg)

    # Build a mutable copy with the modified field
    new_msg = merge(
        REPLy.mutable_copy(msg),
        Dict{String,Any}("code" => fixed, "_include-fixed" => true),
    )
    return next(new_msg)
end
```

`REPLy.mutable_copy(msg)` returns a `Dict{String,Any}` with `String` keys from any
incoming request. It exists because `msg` is an immutable `JSON3.Object` whose
keys are `Symbol`-like, so you cannot mutate it in place or rely on `String` keys.
Merge your changes onto the copy and forward it with `next`.

## Pattern Catalogue

### Pattern 1 — New Op (short-circuit, no session needed)

```julia
struct PingMiddleware <: REPLy.AbstractMiddleware end

REPLy.descriptor(::PingMiddleware) = REPLy.MiddlewareDescriptor(
    provides = Set(["ping"]),
    op_info  = Dict("ping" => Dict{String,Any}(
        "doc" => "Liveness probe.", "requires" => String[], "returns" => ["pong"]
    )),
)

function REPLy.handle_message(::PingMiddleware, msg, next,
                               ctx::REPLy.RequestContext)
    get(msg, "op", "") == "ping" || return next(msg)
    id = String(get(msg, "id", ""))
    return [Dict{String,Any}("id" => id, "pong" => true,
                              "status" => ["done", "pong"])]
end
```

**Wire it:** Place before `UnknownOpMiddleware`. No session routing needed, so
it can go anywhere before the catch-all.

### Pattern 2 — Request Transformer (modifies code before EvalMiddleware)

`IncludeFixMiddleware` rewrites bare `include("f")` →
`Base.include(@__MODULE__, "f")`. Must be placed **before** `EvalMiddleware` in
the stack. See the full implementation above
(§ Modifying a Request Before Forwarding).

**Wire it:** Insert immediately before `EvalMiddleware` using `findfirst`:

```julia
eval_idx = findfirst(mw -> mw isa REPLy.EvalMiddleware, stack)
isnothing(eval_idx) || insert!(stack, eval_idx, IncludeFixMiddleware())
```

### Pattern 3 — Response Augmenter (wraps all ops with side-channel data)

```julia
struct TimingMiddleware <: REPLy.AbstractMiddleware end

function REPLy.handle_message(::TimingMiddleware, msg, next,
                               ctx::REPLy.RequestContext)
    t0     = time_ns()
    result = next(msg)
    ms     = round((time_ns() - t0) / 1_000_000.0, digits=3)
    REPLy.emit!(ctx, Dict{String,Any}("id" => String(get(msg,"id","")),
                                      "timing-ms" => ms))
    return result
end
```

**Wire it:** Near the top of the stack (before `SessionMiddleware`) so it wraps
everything, including session routing overhead.

### Pattern 4 — Observability Op (new op + passive instrumentation)

`MetricsMiddleware` tracks per-op latency/errors and exposes a `metrics` op.
Two responsibilities in one struct: passive (record) + active (respond).

Key points:

- Intercept `metrics` op and return a snapshot
- For all other ops, time the call to `next(msg)` and record the result
- Check for errors by scanning `"error" in get(r, "status", [])` on the
  returned response vector

### Pattern 5 — Op that Delegates to Another Op

```julia
# ReloadFileMiddleware: handles "reload-file", clears a module binding,
# then FORWARDS to "load-file" via next(modified_msg).
#
# CRITICAL: ReloadFileMiddleware must be placed BEFORE LoadFileMiddleware.
function REPLy.handle_message(::ReloadFileMiddleware, msg, next,
                               ctx::REPLy.RequestContext)
    get(msg, "op", "") == "reload-file" || return next(msg)
    id   = String(get(msg, "id", ""))
    file = get(msg, "file", nothing)
    file isa AbstractString || return [REPLy.error_response(id, "file required")]

    sess = ctx.session
    isnothing(sess) && return [REPLy.error_response(id, "session required")]

    # 1. Clear old module binding (if the file defines a module)
    code = read(file, String)
    m = match(r"^\s*(?:bare)?module\s+([A-Za-z_]\w*)"m, code)
    if !isnothing(m)
        sym = Symbol(m.captures[1])
        mod = REPLy.session_module(sess)
        isdefined(mod, sym) && try Base.delete_binding(mod, sym) catch; end
    end

    # 2. Forward as load-file — reuses I/O capture and eval machinery
    load_msg = Dict{String,Any}(
        "op" => "load-file", "id" => id,
        "file" => file, "session" => REPLy.session_id(sess),
    )
    return next(load_msg)   # reaches LoadFileMiddleware (which must be AFTER us)
end
```

Stack order:

```julia
# CORRECT
push!(stack, ReloadFileMiddleware())                # before
push!(stack, REPLy.LoadFileMiddleware(allowlist))   # after

# WRONG — next(load-file) falls through to UnknownOp
push!(stack, REPLy.LoadFileMiddleware(allowlist))
push!(stack, ReloadFileMiddleware())
```

### Pattern 6 — Session Introspection Op (reads session module directly)

```julia
function REPLy.handle_message(::SessionToolsMiddleware, msg, next,
                               ctx::REPLy.RequestContext)
    op = String(get(msg, "op", ""))
    op in ("ls-bindings", "macroexpand") || return next(msg)
    id = String(get(msg, "id", ""))

    sess = ctx.session
    isnothing(sess) && return [REPLy.error_response(id, "$op requires a session")]
    mod = REPLy.session_module(sess)

    if op == "ls-bindings"
        bindings = [
            Dict{String,Any}("name" => string(s), "type" => string(typeof(getfield(mod,s))))
            for s in names(mod; all=true)
            if !startswith(string(s), "#") && s ∉ (:eval, :include) &&
               isdefined(mod, s) && !(getfield(mod, s) isa Module)
        ]
        return [REPLy.response_message(id, "bindings" => bindings,
                                        "count" => length(bindings),
                                        "ns" => string(nameof(mod))),
                REPLy.done_response(id)]

    else  # macroexpand
        code = get(msg, "code", nothing)
        code isa AbstractString || return [REPLy.error_response(id, "code required")]
        once = get(msg, "once", true)
        expansion = try
            string(macroexpand(mod, Meta.parse(code); recursive=!once))
        catch e
            return [REPLy.error_response(id, sprint(showerror, e))]
        end
        return [REPLy.response_message(id, "expansion" => expansion,
                                        "ns" => string(nameof(mod))),
                REPLy.done_response(id)]
    end
end
```

## Composing a Custom Stack

Start from `default_middleware_stack()` and splice your middlewares in at the
right positions:

```julia
function custom_stack(; metrics_store=MetricsStore(), allowlist=(_ -> true))
    default = REPLy.default_middleware_stack()
    stack   = REPLy.AbstractMiddleware[]

    # 1. Outer wrappers — see everything, go first
    push!(stack, MetricsMiddleware(metrics_store))
    push!(stack, TimingMiddleware())
    push!(stack, PingMiddleware())

    # 2. Walk the default stack; splice custom ops at the right positions
    for mw in default
        if mw isa REPLy.LoadFileMiddleware
            # ReloadFile BEFORE LoadFile (delegation order)
            push!(stack, ReloadFileMiddleware())
            push!(stack, REPLy.LoadFileMiddleware(allowlist))  # replace with allowlist
            push!(stack, SessionToolsMiddleware())
            continue  # skip the original LoadFileMiddleware
        end
        push!(stack, mw)
    end

    # 3. IncludeFix BEFORE EvalMiddleware (transform order)
    eval_idx = findfirst(mw -> mw isa REPLy.EvalMiddleware, stack)
    isnothing(eval_idx) || insert!(stack, eval_idx, IncludeFixMiddleware())

    # 4. Validate before returning
    errors = REPLy.validate_stack(stack)
    isempty(errors) || error("Stack validation failed:\n" * join(errors, "\n"))

    return stack
end
```

Start the server with your custom stack:

```julia
server = REPLy.serve(port=5558; middleware=custom_stack())
wait(Condition())
```

## Public API Reference

These symbols are part of the supported middleware-authoring surface (use them
qualified as `REPLy.<name>`):

| Symbol | Type | Purpose |
|--------|------|---------|
| `AbstractMiddleware` | Abstract type | Supertype for all middleware |
| `MiddlewareDescriptor` | Struct | Declares `provides`/`requires`/`op_info` |
| `RequestContext` | Struct | Per-request context (session, manager, state) |
| `descriptor(mw)` | Function | Override to declare op metadata |
| `handle_message(mw, msg, next, ctx)` | Function | Override to handle ops |
| `emit!(ctx, msg)` | Function | Inject a message before the terminal response |
| `session_module(session)` | Function | Get the Julia `Module` behind a session |
| `session_id(session)` | Function | Get the session UUID string |
| `validate_stack(stack)` | Function | Check for conflicts before server start |
| `default_middleware_stack()` | Function | The default ordered stack |
| `done_response(id)` | Function | Build `{"id":id,"status":["done"]}` |
| `error_response(id, msg)` | Function | Build an error terminal response |
| `response_message(id, pairs...)` | Function | Build a non-terminal response frame |
| `mutable_copy(msg)` | Function | Copy a request to a `Dict{String,Any}` (string keys) before modifying/forwarding |
| `AuditLog` / `AuditMiddleware` | Struct | Built-in audit logging (not in default stack) |

Internal (not part of the supported surface — do not depend on):

| Symbol | Why you might want it | Alternative |
|--------|------------------------|-------------|
| `_run_load_file_core` | Full I/O capture for file eval | Forward as `load-file` op via `next` |
| `_run_eval_core` | Full I/O capture for arbitrary code | Forward as `eval` op |
| `with_session_eval` | Session eval serialisation | Forward as `eval` op |

## Enabling the Built-in Audit Middleware

`AuditMiddleware` exists but is not in the default stack. Wire it in to get a
rotating JSON log of every operation:

```julia
log = REPLy.AuditLog(path="logs/audit.jsonl", rotate_bytes=50_000_000)

stack = vcat(
    [REPLy.AuditMiddleware(log)],   # first — captures everything
    REPLy.default_middleware_stack(),
)

REPLy.serve(port=5555; middleware=stack)
```

Each log line is a JSON object with `timestamp`, `operation`, `session_id`,
`source_ip`, `success`, and `error` fields.

## Troubleshooting: Common Fail-States

| Symptom | Cause | Fix |
|---------|-------|-----|
| `MethodError: handle_message is ambiguous` on first request | `ctx` parameter is untyped in your override | Add `::REPLy.RequestContext` to every `handle_message` signature |
| `{"err":"Unknown operation: my-op"}` despite correct `handle_message` | Your middleware is placed after `UnknownOpMiddleware` | Insert your middleware before `UnknownOpMiddleware` in the stack |
| `{"err":"Unknown operation: load-file"}` from a forwarding middleware | Forwarding middleware is placed after `LoadFileMiddleware` | Swap order: forwarding middleware must come before the target op handler |
| `validate_stack` reports "Duplicate handler for 'eval'" | You added a second `EvalMiddleware` | Remove the duplicate; only one middleware may claim each op name |
| `validate_stack` reports "requires 'session' but no earlier middleware provides it" | Your middleware depends on session routing being done first | Ensure `SessionMiddleware` appears before your middleware in the stack |
| `get(msg, "code", nothing)` returns `nothing` on a valid request | `msg` key lookup is case-sensitive; the field might use a different name | Print `collect(keys(msg))` to see actual field names in the request |
| `emit!` messages appear but in the wrong order | `emit!` appends to `ctx.emitted` which comes before the terminal | Expected behaviour — use `emit!` only for side-channel data, not the primary response |
| Timing middleware shows 0ms for fast ops | `time_ns()` resolution varies by platform | Use `time_ns()` not `time()` for sub-millisecond precision; round to 3 decimal places |
| Session bindings missing from `ls-bindings` output | Sub-modules are filtered (`val isa Module` skip) | Add `using .Foo` inside the session to bring sub-module exports into scope |
| `Base.delete_binding` throws on Julia 1.12 | Binding is `const` (from a previous `const` declaration) | `const` bindings cannot be cleared; create a new session instead |

## Key Mental Models

**`next(msg)` is a stack cursor, not a restart.** Think of `next` as "continue
from my position". If you change `op` in the message, only middlewares below you
in the stack will see the new op. If the handler for that op is above you, it
will never receive it.

**Outer middlewares see everything; inner middlewares see less.** A middleware
at position 1 times every op including `ping` and `metrics`. A middleware at
position 8 (after `SessionMiddleware`) only sees ops that passed session
validation. Place observability concerns near the top, domain logic near its
natural position.

**`emit!` is for side-channel data, not the primary response.** The primary
response comes from the return value of `handle_message`. Use `emit!` for
annotations (timing, metrics, warnings) that should accompany any response
without changing its semantics.

**One middleware, one responsibility.** Julia's multiple dispatch makes it
tempting to handle five ops in one `handle_message`. Resist: `validate_stack`
gets confused, stack traces become opaque, and testing individual ops becomes
harder. One struct per logical concern.
