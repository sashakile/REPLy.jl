---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# REPLy_jl-umg.12 — API, MCP and Documentation UX/DX Review

**Date:** 2026-04-29
**Reviewer:** Claude Sonnet 4.6
**Scope:** README.md, docs/src/*.md, src/mcp_adapter.jl, src/REPLy.jl (exports), tutorial and how-to files

---

## Executive Summary

REPLy.jl's documentation is structurally coherent and reasonably well-organized, but contains several high-friction problems that would block or mislead developers in practice. The five most critical issues are: (1) doc code examples import unexported symbols via `using REPLy:` syntax that works but trains users on implementation-internal APIs; (2) status.md is severely out of date and contradicts implemented features; (3) `mcp_ensure_default_session!` documents the wrong return type; (4) error response examples in howto-sessions.md omit the `"done"` flag that every real error response contains; and (5) tutorial-custom-client.md misidentifies JSON3 as a standard library.

---

## Layer 1 — Discoverability

### Finding D-1 (High): status.md claims Unix sockets are not implemented, but they are

**File:** `docs/src/status.md` (lines 33, 37, 53)
**Severity:** High

`status.md` states "Unix socket and multi-listener transport" is "❌ not implemented", and the capability matrix repeats "not implemented" for this feature. However, `src/server.jl` fully implements `socket_path` support via `listen_unix()`, and `howto-unix-sockets.md` documents this working feature in detail. `server_socket_path()` is also exported from `REPLy.jl`.

A developer reading `status.md` to understand implementation maturity before starting would incorrectly conclude Unix socket support is absent, potentially adding unnecessary indirection or abandoning their integration approach.

**Root cause:** `status.md` was written during an earlier implementation phase and never updated after Unix socket support was added.

---

### Finding D-2 (High): api.md is a stub that provides no usable reference

**File:** `docs/src/api.md` (all lines)
**Severity:** High

The entire API reference page consists of:
```
# API Reference

```@autodocs
Modules = [REPLy]
Order   = [:constant, :function, :type]
```
```

This is a Documenter.jl directive that only renders correctly when the docs are built. Reading the raw file (as a developer browsing GitHub or a linked PR) yields nothing. There is no rendered documentation site link in README.md or index.md pointing readers to where built docs are hosted.

More critically, the public export surface in `src/REPLy.jl` is large and undocumented in prose: dozens of symbols are exported without any narrative explaining which are primary API vs. internal infrastructure. Without a rendered doc site, new integrators have no way to understand the API surface.

---

### Finding D-3 (Medium): The entry-point README is missing installation context for development use

**File:** `README.md` (Installation section)
**Severity:** Medium

The Quick Start uses `julia --project=.` but the Installation section uses `Pkg.add("REPLy")` without any qualification about registry availability. There is no indication whether the package is registered in the General registry or how to add an unregistered package. Given the LLM-generated disclaimer, this is likely not yet a registered package, which means `Pkg.add("REPLy")` would silently fail. New users would encounter an opaque error.

---

## Layer 2 — Learnability

### Finding L-1 (Critical): Docs teach `using REPLy:` patterns for unexported symbols, creating a fragile API surface

**Files:** `docs/src/howto-sessions.md` (lines 33, 168, 184), `docs/src/index.md` (line 102), `docs/src/howto-mcp-adapter.md` (lines 47, 70, 133)
**Severity:** Critical

Multiple doc code examples use `using REPLy: SomeSymbol` for symbols that are NOT in the module's `export` list in `src/REPLy.jl`:

- `SessionManager` — not exported
- `create_named_session!` — not exported
- `EvalMiddleware` — not exported
- `SessionMiddleware` — not exported
- `session_name` — not exported

Examples:
```julia
# howto-sessions.md — SessionManager and create_named_session! not exported
using REPLy: SessionManager, create_named_session!
manager = SessionManager()
create_named_session!(manager, "main")

# index.md — EvalMiddleware and SessionMiddleware not exported
using REPLy: EvalMiddleware, SessionMiddleware
server = REPLy.serve(middleware=[SessionMiddleware(), EvalMiddleware(; max_repr_bytes=100_000)])

# howto-mcp-adapter.md — SessionManager not exported
using REPLy: mcp_call_tool, SessionManager
```

While `using REPLy: X` can access non-exported symbols in Julia (it doesn't require export), the docs present these as the canonical integration path without disclosing that users are depending on implementation internals. This creates fragile integrations that break on refactoring without any deprecation contract. The pattern also tells developers that `SessionManager()` is the normal constructor to call, when the server infrastructure already manages one internally.

**Impact:** Every code sample that builds on `SessionManager` directly is teaching the wrong pattern. The high-level workflow should be: connect via TCP/socket and send protocol messages. The `SessionManager` Julia API is a server-side internal, not a client-side primitive.

---

### Finding L-2 (High): howto-sessions.md error response example omits `"done"` flag

**File:** `docs/src/howto-sessions.md` (lines 119–122, 136–138)
**Severity:** High

Section 5 ("Close a Session") shows this error response for session-not-found:
```json
{"id": "close-1", "status": ["error", "session-not-found"], "err": "Session not found: experiment"}
```

But the actual `session_not_found_response()` in `src/errors.jl` calls `error_response()` which always prepends `"done"` to the status array (via `unique(vcat(String["done"], status_flags))`). The real response is:
```json
{"id": "close-1", "status": ["done", "error", "session-not-found"], "err": "Session not found: experiment"}
```

Similarly, Section 6 shows:
```json
{"id": "req", "status": ["error"], "err": "session name may only contain letters, digits, hyphens, and underscores"}
```
This also omits `"done"`.

A client written following the doc examples would wait forever for a terminal `"done"` after a session-not-found error, because it never arrives according to their understanding — but actually it already came embedded in the one response they received.

---

### Finding L-3 (High): mcp_ensure_default_session! documents wrong return value

**File:** `docs/src/howto-mcp-adapter.md` (line 155)
**Severity:** High

The doc shows:
```julia
session_name = mcp_ensure_default_session!(manager)  # "mcp-default"
```

This suggests the function returns the name string `"mcp-default"`. But the actual implementation in `src/mcp_adapter.jl` (lines 151–154) returns `session_id(session)` — a UUID4 string, not the name alias. The docstring in the source code correctly says "returns the canonical UUID of the session."

Code using the documented pattern would assign a UUID to a variable named `session_name` and then try to use `"mcp-default"` as the session routing key, which would work on the first call but fail unexpectedly if anything expected a UUID.

---

### Finding L-4 (High): mcp_new_session_result documents wrong content format

**File:** `docs/src/howto-mcp-adapter.md` (lines 52–54)
**Severity:** High

The doc shows:
```julia
# result["content"][1]["text"] == "Session: mcp-<uuid>"
```
And line 139:
```julia
session_name = match(r"Session: (mcp-\S+)", result["content"][1]["text"]).captures[1]
```

But `mcp_new_session_result()` in `src/mcp_adapter.jl` (line 165) produces:
```julia
text_block("Session: $uuid")
```
where `uuid` is a bare UUID4 string (e.g., `"f47ac10b-58cc-4372-a567-0e02b2c3d479"`), not prefixed with `"mcp-"`. The regex `r"Session: (mcp-\S+)"` would return `nothing.captures`, crashing with a null dereference.

---

### Finding L-5 (Medium): Tutorial misidentifies JSON3 as a standard library

**File:** `docs/src/tutorial-custom-client.md` (line 20)
**Severity:** Medium

The tutorial states: "We will use Julia's `Sockets` and `JSON3` standard libraries."

`Sockets` is a Julia standard library. `JSON3` is a third-party registered package (`JSON3.jl`), not a standard library. A developer following the tutorial would need to add JSON3 to their project with `Pkg.add("JSON3")`. This is not mentioned anywhere in the tutorial, and a fresh `julia client.jl` would fail with `ERROR: ArgumentError: Package JSON3 not found in current path`.

---

### Finding L-6 (Medium): howto-unix-sockets.md response example omits stdout messages

**File:** `docs/src/howto-unix-sockets.md` (lines 39–42)
**Severity:** Medium

The example response shows:
```json
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

But the code evaluated is `"1 + 1"`, which produces no stdout, so this response is technically correct for that case. However, comparing with index.md (which uses the same code and shows the same response structure), there is inconsistency in the `ns` field format: index.md shows `"##EphemeralSession#1"` while howto-unix-sockets.md shows `"##REPLySession#..."`. The module naming depends on the session type, but this is never explained anywhere — developers may be confused when their live responses don't match either example exactly.

---

## Layer 3 — Productivity

### Finding P-1 (High): No end-to-end MCP integration example exists

**File:** `docs/src/howto-mcp-adapter.md`
**Severity:** High

The MCP adapter how-to explains individual building blocks (`mcp_initialize_result`, `mcp_tools`, `mcp_call_tool`, `mcp_eval_request`, `collect_reply_stream`, `reply_stream_to_mcp_result`) but never shows a working end-to-end example that connects all of them. A developer implementing an MCP server using REPLy as the backend must mentally assemble:
1. Initialize → get tools → enter dispatch loop
2. For `julia_eval`: create transport → call `mcp_eval_request` → `send` → `collect_reply_stream` → `reply_stream_to_mcp_result`
3. For lifecycle tools: call `mcp_call_tool` directly

The critical gap: `julia_eval cannot be dispatched via mcp_call_tool` is buried in a prose paragraph (line 63) rather than highlighted as an architectural constraint. This is the single most important design decision in the adapter — eval requires a live transport while lifecycle ops don't — and it's easy to miss.

---

### Finding P-2 (Medium): index.md Resource Limits section omits required package version for middleware customization

**File:** `docs/src/index.md` (lines 100–108)
**Severity:** Medium

The output truncation example:
```julia
using REPLy
using REPLy: EvalMiddleware, SessionMiddleware

server = REPLy.serve(
    port=5555,
    middleware=[SessionMiddleware(), EvalMiddleware(; max_repr_bytes=100_000)],
)
```

Uses `EvalMiddleware` and `SessionMiddleware`, which are not exported. The middleware stack has ordering constraints (SessionMiddleware must appear in the right position for session routing to work). The code example replaces the entire stack with just two middleware, which loses all other middleware (describe, session_ops, unknown_op, etc.) and would break the server. There is no warning about this.

---

### Finding P-3 (Medium): collect_reply_stream's `pending` parameter is undocumented in user-facing docs

**File:** `docs/src/howto-mcp-adapter.md` (Timeouts section)
**Severity:** Medium

The `pending` parameter of `collect_reply_stream` — which allows callers to share a transport across interleaved concurrent requests — is mentioned only in the source code docstring, not in the how-to. For integrators building multiplexed adapters, this is a critical parameter to know about. Its absence from the docs means users will be forced to read source code to understand how to safely handle concurrent evals.

---

### Finding P-4 (Low): howto-sessions.md sweep task pattern doesn't show integration with serve lifecycle

**File:** `docs/src/howto-sessions.md` (lines 196–227)
**Severity:** Low

The sweep task example shows how to create and cancel a sweep background task in isolation, but doesn't show how to wire it to the server lifecycle (e.g., triggering `put!(stop, nothing)` on server close). A developer implementing session cleanup in a real server would have to figure this out on their own.

---

## Layer 4 — Safety

### Finding S-1 (High): index.md middleware example silently breaks the server

**File:** `docs/src/index.md` (lines 100–108)
**Severity:** High

The resource limits example (repeated under L-1 / P-2) passes a minimal two-element middleware stack `[SessionMiddleware(), EvalMiddleware(...)]` to `serve()`. But the actual `default_middleware_stack()` includes describe, session_ops, interrupt, load_file, complete, lookup, stdin, and unknown_op middleware. By replacing the entire stack with only two elements, the server would:
- Return no response for any op other than `eval` (no `unknown-op` handler)
- Fail to handle session lifecycle ops (`new-session`, `ls-sessions`, `close`, `clone`)
- Not have interrupt support

This is a silent failure — no startup error, just wrong behavior at runtime.

---

### Finding S-2 (Medium): No warning about `close(server)` closing the transport in collect_reply_stream timeout path

**File:** `docs/src/howto-mcp-adapter.md` (Timeouts section)
**Severity:** Medium

The timeout documentation correctly notes that on timeout the transport is closed. But it doesn't warn that this closes the *entire transport connection*, not just the in-flight request. Any other pending requests on the same transport are also silently dropped. For integrators maintaining a persistent connection, this is a data-loss scenario that needs explicit handling.

---

## Layer 5 — Integratability

### Finding I-1 (High): MCP adapter has no transport wiring example showing how to connect to REPLy server

**File:** `docs/src/howto-mcp-adapter.md`
**Severity:** High

The how-to shows `collect_reply_stream(transport, "req-1")` and `send(transport, request)` but never shows how to create an `AbstractTransport` connected to a running REPLy server. The only way to know this is to find `JSONTransport` in the API (not prominently documented) and then construct it manually:
```julia
conn = connect(ip"127.0.0.1", 5555)
transport = JSONTransport(conn, ReentrantLock())
```

This construction is not in any doc. The export shows `JSONTransport` is exported, but there's no example of instantiating one.

---

### Finding I-2 (Medium): Protocol reference doesn't document the `"ns"` field format or meaning

**File:** `docs/src/reference-protocol.md` (Response Stream table)
**Severity:** Medium

The protocol reference shows `ns` as `string | Module name the eval ran in` in the response field table. However, the actual values like `##EphemeralSession#1` or `REPLyNamedSession###REPLyNamedSession#1` are synthetic module names generated by Julia's `gensym`, which are unstable across restarts. Clients that parse or display `ns` need to know it is informational only and will not be stable between sessions. This is not documented.

---

### Finding I-3 (Low): README and index.md Quick Start show different code styles for starting the server

**File:** `README.md` (line 22), `docs/src/index.md` (lines 28–33)
**Severity:** Low

README uses a one-liner bash command form:
```bash
julia --project=. -e 'using REPLy; server = REPLy.serve(port=5555); ...'
```

index.md uses a multi-line Julia code block with comments. These are both valid, but presenting two different patterns without explanation ("use the bash form for quick testing, the Julia block for scripts") creates mild cognitive overhead.

---

### Finding I-4 (Low): MCP stub tools return a raw string error without structured MCP schema guidance

**File:** `src/mcp_adapter.jl` (lines 134–137)
**Severity:** Low

Stub tools return `error_result("$tool_name is not yet implemented")`. The reference in the source code to `DRAFT-004` is an internal tracking reference that appears in the `mcp_stub_result` docstring comment. This internal tracking reference is visible to any MCP client that calls a stub tool, since it's embedded in the error message text via the comment in the source (though the actual error text just says "not yet implemented" — the `DRAFT-004` is in a comment). The stub tools catalog in `howto-mcp-adapter.md` is well-documented; no action needed here.

---

## Summary Matrix

| ID | Severity | Category | File |
|---|---|---|---|
| L-1 | Critical | API Design / Learnability | howto-sessions.md, index.md, howto-mcp-adapter.md |
| L-2 | High | Docs Accuracy | howto-sessions.md |
| L-3 | High | Docs Accuracy | howto-mcp-adapter.md |
| L-4 | High | Docs Accuracy | howto-mcp-adapter.md |
| D-1 | High | Docs Staleness | status.md |
| D-2 | High | Docs Gap | api.md |
| P-1 | High | Docs Gap | howto-mcp-adapter.md |
| S-1 | High | Safety / Docs | index.md |
| I-1 | High | Integratability Gap | howto-mcp-adapter.md |
| L-5 | Medium | Docs Accuracy | tutorial-custom-client.md |
| L-6 | Medium | Docs Clarity | howto-unix-sockets.md |
| P-2 | Medium | Docs Gap | index.md |
| P-3 | Medium | Docs Gap | howto-mcp-adapter.md |
| S-2 | Medium | Safety / Docs | howto-mcp-adapter.md |
| I-2 | Medium | Protocol Docs | reference-protocol.md |
| D-3 | Medium | Discoverability | README.md |
| P-4 | Low | Docs Gap | howto-sessions.md |
| I-3 | Low | Docs Style | README.md, index.md |
| I-4 | Low | API Design | mcp_adapter.jl |

---

## Distinction: User-Facing Docs vs. API Design Problems

**User-facing documentation problems** (fixable without code changes):
- D-1: status.md staleness (update the matrix)
- L-2: Missing `"done"` in error examples (fix the JSON)
- L-3: Wrong return type comment for `mcp_ensure_default_session!` (fix the comment)
- L-4: Wrong regex pattern for `mcp_new_session_result` output (fix the example)
- L-5: JSON3 misidentified as standard library (fix the prose)
- L-6: Inconsistent `ns` field values (clarify with a note)
- P-1: Missing end-to-end MCP example (add one)
- P-3: `pending` parameter undocumented (add to how-to)
- S-2: Transport close warning missing (add admonition)
- I-1: No transport construction example (add snippet)
- I-2: `ns` field stability not documented (add note)
- I-3: Style inconsistency (minor, add note)

**API design problems** (require code or export changes):
- L-1 (Critical): `SessionManager`, `create_named_session!`, `EvalMiddleware`, `SessionMiddleware`, `session_name` are not exported but docs use them as primary API. Resolution requires either: (a) exporting them formally, or (b) removing direct `SessionManager` usage from user-facing docs and replacing with higher-level patterns.
- D-2 (High): api.md autodoc stub is useless without a rendered doc site. Resolution requires either hosting docs or replacing with hand-written prose.
- S-1 (High): Replacing the full middleware stack silently degrades the server. Resolution requires either: (a) exporting a `with_max_repr_bytes(n)` helper that patches only EvalMiddleware in the default stack, or (b) adding runtime startup validation that warns on missing critical middleware.
