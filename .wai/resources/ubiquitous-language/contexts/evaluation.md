# Evaluation Context

Scope: everything involved in running Julia code — parsing, I/O capture,
result handling, timeouts, and interrupts. This is the heart of the server.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Eval Request** | A message with `op: "eval"`. Required: `code`. Optional: `session`, `module`, `timeout-ms`, `allow-stdin`, `silent`, `store-history`. |
| **Code** | Julia source string submitted for evaluation. An empty string is valid and returns `nothing`. |
| **Module Path** | Dotted string (e.g., `"Main.Foo.Bar"`) resolved to a target `Module` before eval. Defaults to the session's module. |
| **Eval Task** | The Julia `Task` executing the submitted code. Assigned before execution begins; cleared on completion. The target of `interrupt`. |
| **Eval Lock** | Per-session `Channel{Nothing}(1)` ensuring FIFO serialization. One eval at a time per session. |
| **IO Capture Lock** | Process-global lock serializing `redirect_stdout` / `redirect_stderr` calls (they are process-level operations in Julia < 1.11). |
| **Stdout Buffer** | Captured standard output text for the current eval. Emitted as one or more `out`-field messages before the value. |
| **Stderr Buffer** | Captured standard error / warnings text. Emitted as one or more `err`-field messages before the value. |
| **Value** | The result of evaluating the last expression in `code`. Represented as a string via `repr()`. |
| **Value Repr** | The string form of the value, truncated at `max_value_repr_bytes` (default 1 MB). Truncated values end with `"…[truncated]"`. |
| **Namespace** (`ns`) | The module name where the code was evaluated; returned in the response. |
| **Parse Error** | Thrown by `Meta.parseall(code)` on syntax error. Returns an error response; never reaches `Core.eval`. |
| **Runtime Error** | Any exception raised during `Core.eval`. Returns an error response including exception type, message, and stacktrace. |
| **Parsed Expr** | The `Expr` produced by `Meta.parseall(code)`. Passed to `Core.eval` if parsing succeeds. |
| **Pre-Eval Hook** | A callback invoked before each eval in a named session (e.g., `Revise.revise()`). |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Parse Code** | `Meta.parseall(code)` → `Expr` or throw `ParseError`. |
| **Resolve Module** | Walk the dotted path from `Main` to find the target `Module`. Returns an error if any segment is missing. |
| **Redirect Stdout** | Capture output with task-scoped `redirect_stdout` (Julia 1.11+). Prevents cross-task output leakage. |
| **Redirect Stderr** | Capture warnings and errors with task-scoped `redirect_stderr`. |
| **Evaluate** | `Core.eval(module, expr)` inside the captured I/O context. |
| **Emit Output Chunks** | Stream captured stdout and stderr as separate response messages before the value message. |
| **Truncate Result** | `truncate_output(repr(value), max_bytes)` — append `"…[truncated]"` if the repr exceeds the limit. |
| **Handle Interrupt** | Catch `InterruptException`; emit `status: ["done", "interrupted"]`. Not classified as `"error"`. |
| **Handle Timeout** | Catch `TimeoutError` after `max_eval_time_ms`; emit `status: ["done", "error", "timeout"]`. |
| **Call Pre-Eval Hooks** | Execute registered hooks (e.g., `Revise.revise()`) before named-session evals. |

## Eval Request Fields

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `code` | string | — | Julia source to evaluate |
| `session` | string | (ephemeral) | Target session UUID or alias |
| `module` | string | session module | Dotted module path override |
| `timeout-ms` | integer | 60,000 | Wall-clock deadline; capped at `max_eval_time_ms` |
| `allow-stdin` | boolean | `true` | If `false`, raise `EOFError` on `readline()` instead of blocking |
| `silent` | boolean | `false` | Suppress the `value` response; still emit stdout/err and errors |
| `store-history` | boolean | `true` | Whether to save the result to `session.history` |

## Response Shape

A successful eval produces (in order):
1. Zero or more `{ "id": …, "out": "…" }` messages (stdout chunks)
2. Zero or more `{ "id": …, "err": "…" }` messages (stderr chunks, not errors)
3. One `{ "id": …, "value": "…", "ns": "…", "status": ["done"] }` message (unless `silent: true`)

An errored eval produces:
1. Any stdout/stderr chunks emitted before the exception
2. One `{ "id": …, "err": "…", "ex": {…}, "stacktrace": […], "status": ["done","error"] }` message

## Important Distinctions

- **`err` as output vs. `err` as error summary** — an `err` field *without* `"error"` in `status` is a stderr chunk. An `err` field *with* `"error"` in `status` is the error summary string.
- **Interrupted ≠ Error** — `status: ["done","interrupted"]` does not include `"error"`. A client MUST NOT treat it as a failure.
- **Empty code** — valid; evaluates to `nothing`; not a parse error.
- **Quiet mode** (`silent: true`) — suppresses the `value` message; stdout/stderr chunks and error responses are still sent.

## Concurrency

| Concern | Mechanism |
|---------|-----------|
| Per-session serialization | Eval Lock (Channel, FIFO) |
| Global I/O isolation | IO Capture Lock |
| Server-wide concurrency cap | `max_concurrent_evals` counter + bounded queue |
| Cross-task stdout safety | Per-task redirect (Julia 1.11+) |
