# Change: Restore global stdout/stderr on server close (A4)

## Why

`io_capture.jl:64-65` reassigns process-global `Base.stdout`/`Base.stderr` to the capturer, saving originals as `fallback` (`:62-63`). No `restore_io_capture!` exists and `server.jl`'s close path never calls one. Streams stay swapped for the process lifetime. Benign in standalone mode; breaks embedding (e.g., tests that check stdout after a server session).

## What Changes

- Add `restore_io_capture!` function that restores originals
- Call it from `close_server!`
- Document the swap as process-lifetime mutation if embedding is not a concern

## Impact

- Affected specs: `security`
- Affected code: `src/io_capture.jl`, `src/server.jl`
