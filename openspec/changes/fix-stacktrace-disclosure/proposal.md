# Change: Split internal vs. user error boundary — correlation id + server log (R3, A3)

## Why

`eval_error_response` is identical to `internal_error_response` (`errors.jl:80-81`), so genuine server-internal failures return full stack traces (absolute paths, package paths, frames) to any client. The server's own docs warn "no authentication" (`server.jl:12-15`). This is an info-disclosure release blocker for shared/public use.

## What Changes

- Split `internal_error_response` from `eval_error_response`
- Internal failures return a stable error code + correlation id only
- Full trace is logged server-side only
- Gate trace exposure behind an opt-in limit (default off for non-loopback)

## Impact

- Affected specs: `error-handling`
- Affected code: `src/errors.jl`
- Release blocker: R3
