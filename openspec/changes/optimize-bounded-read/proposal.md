# Change: Optimize read_bounded_line — chunked read (Part C)

## Why

`read_bounded_line` (`message.jl:36-49`) reads one byte at a time — the only real per-request hot loop. Chunked read with a reusable per-connection buffer eliminates the per-byte overhead.

## What Changes

- Replace byte-at-a-time loop with chunked read + buffer scan
- Reuse per-connection buffer (avoid per-request allocation)

## Impact

- Affected specs: `transport`
- Affected code: `src/message.jl`