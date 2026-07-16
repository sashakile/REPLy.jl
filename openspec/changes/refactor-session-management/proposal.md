# Change: NamedSession lock ownership documentation + StdinFeeder value (B5)

## Why

`stdin_pipe`/`stdin_feeder` must be created and torn down as a unit (else libuv-handle/task leak), but their guard (`eval_lock`, not `session.lock`) lives only in comments. Other fields (`history`, `eval_count`, `eval_id`, `created_at`) have undocumented lock ownership. This implicit coupling makes refactoring error-prone.

## What Changes

- Add one authoritative "field → lock" table on the `NamedSession` struct docstring
- Add `@assert islocked(...)` on mutators (pattern already in `io_capture.jl`)
- Encapsulate the stdin pair as one `StdinFeeder` value type
- Tidy-First: no behavior change

## Impact

- Affected specs: `session-management`
- Affected code: `src/session.jl`
