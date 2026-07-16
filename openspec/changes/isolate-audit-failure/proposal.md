# Change: Isolate audit write failure from request path (Step 2, A5)

## Why

`record_audit!` (`audit.jl:28-36`) runs synchronous file I/O under a lock *after* the eval has succeeded. A full/unwritable disk throws, discarding a successful eval result and returning an internal error for an op that completed successfully. Observability outage → request outage.

## What Changes

- Wrap `record_audit!` body in try/catch — audit failures degrade to `@warn`, never abort the request
- Document durable I/O as off the request path (future: async sink)

## Impact

- Affected specs: `security`
- Affected code: `src/security/audit.jl`
- Gate: improvement (post-release)
- Depends on: nothing
