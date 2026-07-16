# Change: Fix `audit_entries` data race — add missing lock (Step 1, 🔴 R2)

## Why

`audit_entries(log) = copy(log.entries)` (`security/audit.jl:91`) takes no lock, racing with concurrent `push!`/`deleteat!` from `record_audit!` and `evict_oldest_entries!` which hold `log.lock`. This is a data race in exported public API — any operator reading the audit log live while the server processes requests can hit a `BoundsError` or torn read.

**Release blocker R2:** ships a known data race in exported public API.

## What Changes

- `lock(log.lock) do; copy(log.entries); end` — one line.
- Verify no other lock-free access to `log.entries`.

## Impact

- Affected specs: `security`
- Affected code: `src/security/audit.jl:91`
- Gate: 🔴 R2 — must fix before public release
- Depends on: nothing